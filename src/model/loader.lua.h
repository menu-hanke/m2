//-- vim: ft=lua:
/* --[[
	Shared loader for ffi/non-ffi Lua models.
	preprocess with: gcc -P -E -nostdinc

	calling conventions:
	    * plain Lua (non-ffi): first parameters are passed, then coefficients. the function returns
		    the model return values. loader converts between C and Lua types. C vectors are
			converted to and from Lua tables.
		* ffi: first parameters are passed, then ffi vectors for set return values, then coefficients.
		    function returns scalar model return values and writes vector return values to the
			corresponding args.
	
	both loader functions return a proxy, that when called for the first time, loads the actual
	function, generates a wrapper and patches the model table entry.
	NOTE: don't store the model table entry anywhere, always use the returned handle in C code.
--]] */

local ffi = require "ffi"
local C = ffi.C

ffi.cdef [[
#define static_assert(...)
#include "model/conv.h"
]]

//-- this definition must match mcall_edge
#define EDGE_CT(ctname) "struct { " .. ctname .. " *p; size_t n; }"

//-- workaround for luajit because otherwise there's no way to alloc the vla via ffi.
//-- this must match struct mt_sig
ffi.cdef [[
	typedef struct {
		uint8_t np, nr;
		mt_type typ[?];
	} sig;
]]

local function isscalar(typ)
	return bit.band(typ, C.MT_SET) == 0
end

local function scalar(typ)
	return bit.band(typ, bit.bnot(C.MT_SET))
end

/*
-- this is duplicated in frontend/model/conv.lua but oh well.
-- we can't access that from this lua state.
-- one way to fix it would be to make it an X macro in model/conv.h but i'll keep it like this
-- for now.
*/
local mt_ctype = {
	[C.MT_SINT8]   = "int8_t",
	[C.MT_SINT16]  = "int16_t",
	[C.MT_SINT32]  = "int32_t",
	[C.MT_SINT64]  = "int64_t",
	[C.MT_UINT8]   = "uint8_t",
	[C.MT_UINT16]  = "uint16_t",
	[C.MT_UINT32]  = "uint32_t",
	[C.MT_UINT64]  = "uint64_t",
	[C.MT_FLOAT]   = "float",
	[C.MT_DOUBLE]  = "double",
	[C.MT_BOOL]    = "bool",
	[C.MT_POINTER] = "void *"
}

local cedge_mt = {
	__index = function(self, i)
		return self.p[i]
	end,

	__newindex = function(self, i, v)
		self.p[i] = v
	end,

	__len = function(self)
		return tonumber(self.n)
	end
}

local totable_f = [[
	return function(self)
		local tab = {}
		for i=0, #self-1 do
			tab[i+1] = self[i]
		end
		return tab
	end
]]

local fromtable_f = [[
	return function(self, tab)
		for i=0, #self-1 do
			self[i] = tab[i+1]
		end
	end
]]

local cedge_ct = setmetatable({}, {
	__index = function(self, ctname)
		self[ctname] = {
			ctype = ffi.metatype(ffi.typeof(EDGE_CT("$"), ffi.typeof(ctname)), cedge_mt),
			-- specialize for each ctype
			totable = load(totable_f)(),
			fromtable = load(fromtable_f)()
		}
		return self[ctname]
	end
})

/* ---------------------------------------------------------------------- */

local models = {}

local function copysig(sig)
	local sc = ffi.new("sig", sig.np+sig.nr)
	ffi.copy(sc, sig, ffi.sizeof("struct mt_sig")+sig.np+sig.nr)
	return sc
end

local function patcher(sig, useffi, name)
	/*
	-- local rv1, ..., rvN = f(
	--     ffi.cast("mc_double_edge *", mc.edges+0).p[0],
	--     totable(ffi.cast("mc_double_edge *e", mc.edges+1),
	--     ...
	--     ffi.cast("type *", mc.edges[np].p)[0]
	-- )
	--
	-- ffi.cast("mc_double_edge *", mc.edges+np).p[0] = rv1
	-- fromtable(ffi.cast("mc_double_edge *", mc.edges+np+1).p, rv2)
	-- ...
	*/
	return function(f)
		local init, params, rv, returns = {}, {}, {}, {}
		local edge_ct = {}

		for i=0, sig.np+sig.nr-1 do
			edge_ct[i] = cedge_ct[mt_ctype[scalar(sig.typ[i])]]
			table.insert(init, string.format("local edge_ct%d = ffi.typeof('$*', edge_ct[%d].ctype)", i, i))
		end

		for i=0, sig.np-1 do
			if isscalar(sig.typ[i]) then
				table.insert(params, string.format("ffi.cast(edge_ct%d, mc.edges+%d).p[0]", i, i))
			elseif useffi then
				table.insert(params, string.format("ffi.cast(edge_ct%d, mc.edges+%d)[0]", i, i))
			else
				table.insert(init, string.format("local edge_totable%d = edge_ct[%d].totable", i, i))
				table.insert(params, string.format("edge_totable%d(ffi.cast(edge_ct%d, mc.edges+%d)[0])", i, i, i))
			end
		end

		for i=sig.np, sig.np+sig.nr-1 do
			if isscalar(sig.typ[i]) then
				table.insert(rv, string.format("rv%d", i))
				table.insert(returns, string.format("ffi.cast(edge_ct%d, mc.edges+%d).p[0] = rv%d", i, i, i))
			elseif useffi then
				table.insert(params, string.format("ffi.cast(edge_ct%d, mc.edges+%d)[0]", i, i))
			else
				table.insert(rv, string.format("rv%d", i))
				table.insert(init, string.format("local edge_fromtable%d = edge_ct[%d].fromtable", i, i))
				table.insert(returns, string.format("edge_fromtable%d(ffi.cast(edge_ct%d, mc.edges+%d)[0], rv%d)", i, i, i, i))
			end
		end
		
		return load(string.format([[
				local ffi = ffi
				local f = f
				%s

				return function(mc)
					mc = ffi.cast("mcall_s *", mc)
					%s f(%s)
					%s
				end
			]],
			table.concat(init, "\n"),
			--[[]] #rv > 0 and string.format("local %s =", table.concat(rv, ", ")) or "",
			table.concat(params, ", "),
			table.concat(returns, "\n")
			), string.format("=patch@%s", name), nil, {
				edge_ct = edge_ct,
				f       = f,
				ffi     = ffi
			})()
	end
end

local function proxy(module, name, sig, useffi)
	local patch = patcher(copysig(ffi.cast("struct mt_sig *", sig)), useffi, name)
	local handle = #models+1
	models[handle] = function(mc)
		local f = require(module)[name] or
			error(string.format("module \'%s\' doesn\'t export \'%s\'", module, name))
		f = patch(f)
		models[handle] = f
		return f(mc)
	end
	return handle
end

return models, proxy
