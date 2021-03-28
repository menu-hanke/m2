local code = require "code"
local misc = require "misc"
local ctypes = require "fhk.ctypes"
local ffi = require "ffi"
local C = ffi.C

local function dispatch_template(dispinfo, upv, src, chunkname)
	upv = upv or {}
	local out = code.new()

	out:emit([[
		local C, D, J = C, dispinfo.dispatch, dispinfo.jumptable
	]])

	for name,_ in pairs(upv) do
		out:emitf("local %s = %s", name, name)
	end

	out:emit("return function(S, A)")
	out:emit(src)
	out:emit([[
		return J[C.fhkD_continue(S, D)](S, A)
		end
	]])

	return out:compile(misc.merge({dispinfo=dispinfo, C=C}, upv),
		string.format("=(dispatch@%s)", chunkname))()
end

local function setvalue_constptr(dispinfo, xi, ptr, num, name)
	return dispatch_template(
		dispinfo,
		nil,
		-- tonumber is safe here, double can fit 52 bits
		string.format("C.fhkD_setvaluei_u64(S, %d, 0, %d, 0x%x)", xi, num, tonumber(ptr)),
		string.format("%s->%p", name or xi, ptr)
	)
end

local function setvalue_userfunc_offset(dispinfo, xi, f, offset, name)
	return dispatch_template(
		dispinfo,
		{_f=f},
		string.format([[
			local inst = D.arg_ref.inst
			local ptr = _f(inst, A)
			C.fhkD_setvaluei_offset(S, %d, inst, 1, ptr, %d)
		]], xi, offset or 0),
		string.format("%s->%s+%s", name or xi, f, offset)
	)
end

local function setvalue_array_userfunc(dispinfo, xi, f, name)
	return dispatch_template(
		dispinfo,
		{_f=f},
		string.format([[
			local ptr, inst, num = _f(D.arg_ref.inst, A)
			C.fhkS_setvaluei(S, %d, inst, num, ptr)
		]], xi),
		string.format("%s->%s", name or xi, f)
	)
end

local function setvalue_soa_constptr(dispinfo, xi, ptr, band, name)
	return dispatch_template(
		dispinfo,
		{_ptr=ptr},
		string.format("C.fhkS_setvaluei(S, %d, 0, #_ptr, _ptr.%s)", xi, band),
		string.format("%s->%p#%s", name or xi, ptr, band)
	)
end

local function setvalue_soa_userfunc(dispinfo, xi, f, band, name)
	return dispatch_template(
		dispinfo,
		{_f=f},
		string.format([[
			local ptr, inst = _f(D.arg_ref.inst, A)
			C.fhkS_setvaluei(S, %d, inst, #ptr, ptr.%s)
		]], xi, band),
		string.format("%s->%s#%s", name or xi, f, band)
	)
end

-- TODO: move this somewhere else (modcall.lua ?)
local tonumber = tonumber
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

local function specialize_edge_ct(ctype)
	return ffi.metatype(ffi.typeof([[
		struct {
			$ *p;
			size_t n;
		}	
	]], ctype), cedge_mt)
end

local cedge_ct = setmetatable({}, {
	__index = function(self, ctype)
		local ctid = tonumber(ctype)
		local ct = rawget(self, ctid)
		if ct then return ct end
		self[ctid] = {
			ctype = specialize_edge_ct(ctype),
			-- specialize for each ctype
			totable = load(totable_f)(),
			fromtable = load(fromtable_f)()
		}
		return self[ctid]
	end
})

local function signature_ctype(signature)
	assert(ffi.offsetof(ctypes.modcall, "edges") == ffi.sizeof("uintptr_t"))

	local fields = { "uintptr_t ___header;" }
	local ctypes = {}

	for i,p in ipairs(signature.params) do
		table.insert(fields, string.format("$ param%d;", i))
		table.insert(ctypes, cedge_ct[p.ctype].ctype)
	end

	for i,r in ipairs(signature.returns) do
		table.insert(fields, string.format("$ return%d;", i))
		table.insert(ctypes, cedge_ct[r.ctype].ctype)
	end

	return ffi.typeof(string.format("struct { %s }", table.concat(fields, "\n")), unpack(ctypes))
end

local function modcall_lua() error("TODO") end

local function modcall_lua_ffi(dispinfo, signature, f, name)
	assert(#signature.returns > 0)
	
	local params, returns = {}, {}

	for i,p in ipairs(signature.params) do
		if p.scalar then
			table.insert(params, string.format("call.param%d[0]", i))
		else
			table.insert(params, string.format("call.param%d", i))
		end
	end

	for i,r in ipairs(signature.returns) do
		if r.scalar then
			table.insert(returns, string.format("call.return%d[0]", i))
		else
			table.insert(params, string.format("call.return%d", i))
		end
	end

	return dispatch_template(
		dispinfo,
		{
			_signature_ctp = ffi.typeof("$*", signature_ctype(signature)),
			_f = f,
			cast = ffi.cast,
		},
		string.format([[
			local call = cast(_signature_ctp, D.arg_ptr)
			%s _f(%s)
		]],
		#returns > 0 and string.format("%s =", table.concat(returns, ", ")) or "",
		table.concat(params, ", ")),
		string.format("modcall-lua-ffi@%s", name or f)
	)
end

-- TODO: autoconversion:
-- * either use ffi.new for allocation, or have a temporary conversion buffer in D
--   (ff models can't call back into Lua, so it's ok to share the conversion buffer,
--   and having it in D means its auto-gc'd with D)
-- * have ff models return a broader sigset, then generate autoconversion code for
--   each non-matching param/return
-- * the autoconversion should be implemented separate of ff, it might be useful in other
--   models as well
local function modcall_fff(dispinfo, F, lang, handle, name)
	return dispatch_template(
		dispinfo,
		{ F = F },
		string.format([[
			if C.fff%s_call(F, %s, D.arg_ptr) ~= 0 then
				F:raise(true)
			end
		]], lang, tostring(ffi.cast("uint64_t", handle))),
		string.format("modcall-fff-%s@%s", lang, name or handle)
	)
end

local function modcall_const(dispinfo, signature, returns)
	assert(#returns == #signature.returns)

	local np = #signature.params-1
	local src, upv = code.new(), {}

	upv.modcall_ct = ctypes.modcall_p
	src:emit("local call = cast(modcall_ct, D.arg_ptr)")

	for i,r in ipairs(returns) do
		local ctype = signature.returns[i].ctype

		if type(r) == "table" then
			r = ffi.new(ffi.typeof("$[?]", ctype), #r, r)
		end

		if type(r) == "cdata" then
			-- TODO: should support scalar cdata
			upv.copy = ffi.copy
			upv[string.format("return%d", i)] = r
			src:emitf(
				"copy(call.edges[%d].p, return%d, call.edges[%d].n*%d)",
				np+i, i, np+i, ffi.sizeof(ctype)
			)
		elseif type(r) == "number" then
			upv.cast = ffi.cast
			upv[string.format("return%d_ctype", i)] = ffi.typeof("$*", ctype)
			src:emitf(
				"cast(return%d_ctype, call.edges[%d].p)[0] = %d",
				i, np+i, r
			)
		else
			error(string.format("unhandled constant: %s", r))
		end
	end

	return dispatch_template(dispinfo, upv, tostring(src), string.format("modcall-const@%p", returns))
end

-- TODO: maybe this should alloc the map on the solver arena?
local function mapcall_i(dispinfo, idx, map)
	return dispatch_template(
		dispinfo,
		{ _map = map, },
		string.format([[
			local inst = D.arg_ref.inst
			C.fhkS_setmap(S, %d, inst, _map(inst))
		]], idx),
		string.format("imapcall%d@%p", idx, map)
	)
end

local function mapcall_k(dispinfo, idx, map)
	return dispatch_template(
		dispinfo,
		{ _map = map },
		string.format("C.fhkS_setmap(S, %d, 0, _map())", idx),
		string.format("kmapcall%d@%p", idx, map)
	)
end

local function solver_trampoline(name)
	-- TODO: the error handling code doesn't belong here. it would be nicer to have
	-- pushstate/popstate work in a way that doesn't require a protected call
	-- (ie. eliminate popstate and only have pushstate/getstate). return from the
	-- xpcall isn't compiled (and it produces less nice backtraces).
	-- this doesn't really have a performance impact because most of the time is spent
	-- in the solver, but it would be nicer to not have to do this.

	return code.new()
		:emit([[
			local _solve, _pushstate, _popstate
			local xpcall, traceback, error = xpcall, traceback, error
			return function(A, B)
				local ok, x = xpcall(_solve, traceback, A, B, _pushstate(A))
				_popstate()
				if not ok then error(x) end
				return x
			end
		]])
		:compile({
			xpcall    = xpcall,
			traceback = debug.traceback,
			error     = error
		}, string.format("=(solver-trampoline@%s)", name or "?"))()
end

local function bind_trampoline(trampoline, solve, pushstate, popstate)
	code.setupvalue(trampoline, "_solve", solve)
	code.setupvalue(trampoline, "_pushstate", pushstate)
	code.setupvalue(trampoline, "_popstate", popstate)
end

local function solver_ctype(roots)
	local fields, ctypes = {}, {}

	for _,v in ipairs(roots) do
		table.insert(fields, string.format("$ *%s;", v.name))
		table.insert(ctypes, v.ctype)
	end

	return ffi.typeof(string.format("struct { %s }", table.concat(fields, "")), unpack(ctypes))
end

-- roots:
--     name (required)     name in result cdata, must be a valid C identifier
--     idx (required)      variable index in G
--     ctype (required)    type in result cdata
--     subset              subset to solve.
--                         cdata -> fixed subset
--                         non-cdata -> read key (index table or cdata) from A
--                         nil -> solve full space (requires shape table)
--     nopack              set FHKF_NPACK (don't pack result, requires shape table)
--     group               group index, required if subset is implicit space or nopack is set
local function solver(dispinfo, alloc, roots, name)
	local res_ct = solver_ctype(roots)

	local src = code.new()

	for i,v in ipairs(roots) do
		if v.subset and type(v.subset) ~= "cdata" then
			src:emitf("local __subset_%d = roots[%d].subset", i, i)
		end
	end

	src:emitf([[
		local C, cast, type = C, cast, type
		local D, J = dispinfo.dispatch, dispinfo.jumptable
		local space, size, ssfromidx = space, size, ssfromidx
		local res_ct = res_ct
		local _alloc = alloc

		return function(A, B, S, arena, shape)
			local result = cast(res_ct, _alloc(%d, %d))
	]], ffi.sizeof(res_ct), ffi.alignof(res_ct))

	for i,v in ipairs(roots) do
		local cts, cta = ffi.sizeof(v.ctype), ffi.alignof(v.ctype)

		src:emit("do")

		if type(v.subset) == "cdata" then -- const subset
			src:emitf([[
				local buf = _alloc(%d, %d)
				C.fhkS_setroot(S, %d, %s, buf)
			]],
			ctypes.ss_size(v.subset)*cts, cta,
			v.idx, v.subset)
		elseif v.subset then -- keyed subset
			src:emitf([[
				local ss = B[__subset_%d]
				local num
				if type(ss) == "table" then
					num = #ss
					ss = ssfromidx(ss, arena)
				else
					num = size(ss)
				end
				local buf = _alloc(num*%d, %d)
				C.fhkS_setroot(S, %d, ss, buf)
			]],
			i,
			cts, cta,
			v.idx)
		else -- implicit space
			src:emitf([[
				local buf = _alloc(shape[%d]*%d, %d)
				C.fhkS_setroot(S, %d, space(shape[%d]), buf)
			]],
			v.group, cts, cta,
			v.idx, v.group)
		end

		src:emitf("result.%s = buf end", v.name)
	end

	src:emit([[
		J[C.fhkD_continue(S, D)](S, A)
		return result
		end
	]])

	return src:compile({
		C            = C,
		cast         = ffi.cast,
		type         = type,
		dispinfo     = dispinfo,
		space        = ctypes.space,
		size         = ctypes.ss_size,
		ssfromidx    = ctypes.ssfromidx,
		res_ct       = ffi.typeof("$*", res_ct),
		alloc        = alloc,
		roots        = roots
	}, string.format("=(solver@%s)", name or string.format("%p", roots)))()
end

local function uniq(funs)
	local have = {}
	local ret = {}

	for _,f in ipairs(funs) do
		if not have[f] then
			have[f] = true
			table.insert(ret, f)
		end
	end

	return ret
end

local function shapefunc(funs)
	funs = uniq(funs)
	if #funs == 0 then return end
	if #funs == 1 then return funs[1] end

	local out = code.new()

	for i=1, #funs do
		sf:emitf("local shapef%d = funs[%d]", i, i)
	end

	out:emit([[
		return function(state)
			local shape = shapef1(state)
			local s
	]])

	for i=2, #funs do
		out:emitf([[
			s = shapef%d(state)
			if s ~= shape then goto fail end
		]], i)
	end

	out:emit([[
			do return shape end
::fail::
			error(string.format("groups disagree about shape: %d != %d", shape, s))
		end
	]])

	return out:compile({funs=funs, error=error}, string.format("=(groupshape@%p)", funs))()
end

local function pushstate_uncached(G, shapef, obtain)
	local src = code.new()

	local i = 0
	while shapef[i] do
		src:emitf("local __shape_%d = shapef[%d]", i, i)
		i = i+1
	end

	src:emitf([[
		local C, G = C, G
		local cast = cast
		local _obtain = obtain

		return function(A)
			local arena = _obtain()
			local shape = cast("fhk_inst *", C.arena_alloc(arena, %d, %d))
	]], i*ffi.sizeof("fhk_inst"), ffi.alignof("fhk_inst"))

	for j=0, i-1 do
		src:emitf("shape[%d] = __shape_%d(A)", j, j)
	end

	src:emit("local S = C.fhk_create_solver(G, arena)")

	for j=0, i-1 do
		src:emitf("C.fhkS_setshape(S, %d, shape[%d])", j, j)
	end

	src:emit([[
			return S, arena, shape
		end
	]])

	return src:compile({
		C      = C,
		G      = G,
		cast   = ffi.cast,
		obtain = obtain,
		shapef = shapef
	}, string.format("=(pushstate-uncached@%p)", shapef))()
end

return {
	setvalue_constptr        = setvalue_constptr,
	setvalue_userfunc_offset = setvalue_userfunc_offset,
	setvalue_array_userfunc  = setvalue_array_userfunc,
	setvalue_soa_constptr    = setvalue_soa_constptr,
	setvalue_soa_userfunc    = setvalue_soa_userfunc,
	modcall_lua              = modcall_lua,
	modcall_lua_ffi          = modcall_lua_ffi,
	modcall_fff              = modcall_fff,
	modcall_const            = modcall_const,
	mapcall_i                = mapcall_i,
	mapcall_k                = mapcall_k,
	solver_trampoline        = solver_trampoline,
	bind_trampoline          = bind_trampoline,
	solver                   = solver,
	shapefunc                = shapefunc,
	pushstate_uncached       = pushstate_uncached
}
