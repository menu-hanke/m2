-- this module is the Lua counterpart/"glue" for driver.c/h.
-- the idea is to generate a lua function that will setup the necessary state
-- (see driver.h and mapping.lua) and jump to fhkD_continue.

require "fhk.ctypes"
local code = require "code"
local ctypes = require "fhk.ctypes"
local ffi = require "ffi"
local C = ffi.C

---- status ----------------------------------------

local fhkD_status_ct = ffi.metatype("fhkD_status", {
	__index = {
		fmt_error = function(self, ecode, symbols)
			if ecode == C.FHKDE_CONV then return "type conversion error" end
			if ecode == C.FHKDE_MOD then
				return string.format("model call error: %s", require("model").error())
			end
			if ecode == C.FHKDE_FHK then
				return string.format("fhk failed: %s", ctypes.fmt_error(
					ctypes.status_arg(self.e_status).s_ei, symbols))
			end

			assert(false)
		end
	}
})

-- Note: a global status will not cause a race condition. the status will be immediately
-- handled after solver return, so it doesn't matter if a recursive call/virtual overwrites it.
local g_status = fhkD_status_ct()

---- driver loop ----------------------------------------

local dvbuild_mt = { __index={} }
local umem_mt = { __index={} }

local function builder()
	return setmetatable({
		givens       = {},
		models       = {},
		s_given      = 0,
		s_models     = 0
	}, dvbuild_mt)
end

local function umem()
	return setmetatable({
		fields          = {},
		ctype_callbacks = {}
	}, umem_mt)
end

function dvbuild_mt.__index:given(idx, create)
	self.givens[idx] = create
	self.s_given = math.max(self.s_given, idx+1)
end

function dvbuild_mt.__index:model(idx, create)
	self.models[idx] = create
	self.s_models = math.max(self.s_models, idx+1)
end

function dvbuild_mt.__index:create_driver(alloc)
	local umem = umem()

	local d_vars = ffi.cast("fhkD_given *",
		alloc(ffi.sizeof("fhkD_given")*self.s_given, ffi.alignof("fhkD_given")))
	
	for i=0, self.s_given-1 do
		if self.givens[i] then
			self.givens[i](d_vars+i, umem)
		end
	end

	local d_models = ffi.cast("fhkD_model *",
		alloc(ffi.sizeof("fhkD_model")*self.s_models, ffi.alignof("fhkD_model")))
	
	for i=0, self.s_models-1 do
		if self.models[i] then
			self.models[i](d_models+i, umem)
		end
	end

	local D = ffi.cast("fhkD_driver *",
		alloc(ffi.sizeof("fhkD_driver"), ffi.alignof("fhkD_driver")))
	
	
	D.d_vars = d_vars
	D.d_models = d_models
	D.d_maps = nil -- TODO

	return D, umem
end

function umem_mt.__index:scalar(ctype, init)
	local name = string.format("_%d", #self.fields)
	table.insert(self.fields, {
		ctype = ctype,
		init  = init,
		name  = name
	})
	return name
end

function umem_mt.__index:on_ctype(f)
	table.insert(self.ctype_callbacks, f)
end

function umem_mt.__index:ctype()
	if self._ctype then
		return self._ctype
	end

	table.sort(self.fields, function(a, b)
		return ffi.sizeof(a.ctype) > ffi.sizeof(b.ctype)
	end)

	local ctypes, fields = {}, {}
	for _,f in ipairs(self.fields) do
		table.insert(ctypes, f.ctype)
		table.insert(fields, string.format("$ %s;", f.name))
	end

	self._ctype = ffi.typeof(
		string.format("struct { %s }", table.concat(fields, " ")),
		unpack(ctypes)
	)

	for _,f in ipairs(self.ctype_callbacks) do
		f(self._ctype)
	end

	return self._ctype
end

-- opt:
--     alloc : alloc(size, align) -- note the memory must outlive the driver function
--     loop  : loop -- loop function
--
-- this generates a function that inits umem and hands control to the driver loop.
-- note: this is per-subgraph, not per-solver.
-- note: the solver must have a shape table set when entering the generated function, this function
--       will error if the solver requests shape.
function dvbuild_mt.__index:compile(opt)
	local D, umem = self:create_driver(opt.alloc)
	local caller = code.new()

	caller:emit([[
		local ffi = require "ffi"
		local C, cast = ffi.C, ffi.cast
		local driver, symbols, loop, g_status = driver, symbols, loop, g_status
		local umem_ctp = ffi.typeof("$*", umem:ctype())
	]])

	for i=1, #umem.fields do
		caller:emitf("local __init_%d = umem.fields[%d].init", i, i)
	end

	local uct = umem:ctype()
	caller:emitf([[
		return function(state, solver, arena)
			local u = cast(umem_ctp, C.arena_alloc(arena, %d, %d))
	]], ffi.sizeof(uct), ffi.alignof(uct))

	for i,field in ipairs(umem.fields) do
		caller:emitf("u.%s = __init_%d(state)", field.name, i)
	end

	-- TODO: FHKDL_* virtual callbacks
	caller:emitf([[
		while true do
			local code = %s(solver, driver, g_status, arena, u)

			if code == C.FHK_OK then
				return
			end

			if code < 0 then
				return g_status:fmt_error(code, symbols)
			end

			assert(false)
		end
	end
	]], opt.loop and "loop" or "C.fhkD_continue")

	return caller:compile({
		require  = require,
		loop     = opt.loop,
		symbols  = opt.symbols,
		driver   = D,
		umem     = umem,
		g_status = g_status
	}, string.format("=(driverinit@%p)", self))()
end

---- models calls ----------------------------------------

local function conv(g_sig, m_sig, alloc)
	local convs = {}

	for i=0, g_sig.np-1 do
		if g_sig.typ[i] ~= m_sig.typ[i] then
			table.insert(convs, {ei=i, from=g_sig.typ[i], to=m_sig.typ[i]})
		end
	end

	local np = #convs

	for i=g_sig.np, g_sig.np+g_sig.nr-1 do
		if g_sig.typ[i] ~= m_sig.typ[i] then
			table.insert(convs, {ei=i, from=m_sig.typ[i], to=g_sig.typ[i]})
		end
	end

	local n = #convs
	local mconv = nil

	if n > 0 then
		mconv = ffi.cast("fhkD_conv *",
			alloc(n * ffi.sizeof("fhkD_conv"), ffi.alignof("fhkD_conv")))
		
		for i,c in ipairs(convs) do
			mconv[i-1].ei = c.ei
			mconv[i-1].from = c.from
			mconv[i-1].to = c.to
		end
	end

	return mconv, np, n
end

local function mcall(dm, model, conv, np, n)
	dm.tag = C.FHKDM_MCALL
	dm.m_npconv = np or 0
	dm.m_nconv = n or 0
	dm.m_conv = conv or nil
	dm.m_fp = model.call
	dm.m_model = model
	return dm
end

ffi.metatype("fhkD_model", {
	__index = {
		set_mcall = mcall
	}
})

---- vars ----------------------------------------

local function vref(dv, ...)
	local offsets = {...}
	dv.r_num = #offsets
	for i, o in ipairs(offsets) do
		dv.r_off[i-1] = o
	end
	return dv
end

local function vrefk(dv, p, ...)
	dv.tag = C.FHKDV_REFK
	dv.rk_ref = p
	return vref(dv, ...)
end

local function vrefu(dv, offset, ...)
	dv.tag = C.FHKDV_REFU
	dv.ru_udata = offset
	return vref(dv, ...)
end

ffi.metatype("fhkD_given", {
	__index = {
		set_vrefk = vrefk,
		set_vrefu = vrefu
	}
})

--------------------------------------------------------------------------------

return {
	builder           = builder,
	conv              = conv,
	mcall             = mcall,
	vrefk             = vrefk,
	vrefu             = vrefu
}
