local fff = require "fff"
local ctypes = require "fhk.ctypes"
local ffi = require "ffi"
local C = ffi.C

local _anchor = {}
local function anchor()
	local idx = 0
	return function(x)
		_anchor[idx] = x
		idx = idx+1
		return x
	end
end

local function createff(F, ffunc)
	local handle = C["fff"..ffunc.lang.."_create"](F, unpack(ffunc.args))
	F:checkerr(true)
	return handle
end

local function callff(F, ffunc, handle, fc)
	return C["fff"..ffunc.lang.."_call"](F, handle, fc)
end

local function createcall(np, nr)
	local call = ffi.gc(
		ffi.cast(
			ctypes.modcall_p,
			C.malloc(ffi.sizeof(ctypes.modcall) + (np+nr)*2*ffi.sizeof("void *"))
		),
		C.free
	)
	call.np = 0
	call.nr = 0
	return call
end

local function setparams(call, params, anchor)
	call.np = #params
	for i,p in ipairs(params) do
		call.edges[i-1].p = anchor(ffi.new(ffi.typeof("$[?]", p.ctype), #p, p))
		call.edges[i-1].n = #p
	end
end

local function setreturns(call, returns, anchor)
	call.nr = #returns
	for i,r in ipairs(returns) do
		call.edges[call.np+i-1].p = anchor(ffi.new(ffi.typeof("$[?]", r.ctype), #r))
		call.edges[call.np+i-1].n = #r
	end
end

local function checkreturns(call, returns)
	for i,r in ipairs(returns) do
		local p = ffi.cast(ffi.typeof("$*", r.ctype), call.edges[call.np+i-1].p)
		for j,v in ipairs(r) do
			if p[j-1] ~= v then
				error(string.format("return #%d: expected %s, got %s", j, v, p[j-1]))
			end
		end
	end
end

local function checkerr(F, err, ecode)
	if type(err) == "number" then
		if ecode ~= err then
			error(string.format("expected return value %d, got %d", err, ecode))
		end
	elseif type(err) == "string" then
		local emsg = C.fff_errmsg(F)
		if emsg == nil then
			error("expected error message, got none")
		end
		emsg = ffi.string(emsg)
		if not emsg:match(err) then
			error(string.format("unexpected error: %s", emsg))
		end
	elseif not err then
		if ecode == 0 then
			error("expected failure, but succeeded")
		end
	end
end

local function callctx(call, results)
	local F = fff.state()
	local handle = createff(F, call.ffunc)
	local fc = createcall(#call.params, #results)
	local anchor = anchor()
	setparams(fc, call.params, anchor)
	setreturns(fc, results, anchor)
	return F, handle, fc
end

local function result(call, results)
	local F, handle, fc = callctx(call, results)
	callff(F, call.ffunc, handle, fc)
	F:checkerr(true)
	checkreturns(fc, results)
end

local function fails(call, results, err)
	local F, handle, fc = callctx(call, results)
	local e = callff(F, call.ffunc, handle, fc)
	checkerr(F, err, e)
end

local function create_fails(ffunc, err)
	local F = fff.state()
	C["fff"..ffunc.lang.."_create"](F, unpack(ffunc.args))
	checkerr(F, err, C.fff_ecode(F))
end

local call_mt = {
	__index = {
		result = function(self, ...)
			local returns = {...}
			return function()
				return result(self, returns)
			end
		end,
		fails  = function(self, err, ...)
			local returns = {...}
			return function()
				return fails(self, returns, err)
			end
		end,
	}
}

local ffunc_mt = {
	__index = {
		call = function(self, ...)
			return setmetatable({
				ffunc = self,
				params = {...}
			}, call_mt)
		end,
		create_fails = function(self, err)
			return function()
				create_fails(self, err)
			end
		end
	}
}

local function lang(lang)
	if not fff.has(lang) then return end

	return function(...)
		return setmetatable({
			lang = lang,
			args = {...}
		}, ffunc_mt)
	end
end

local function maketyped(ctype)
	ctype = ffi.typeof(ctype)
	return function(...)
		return {ctype=ctype, ...}
	end
end

return {
	lang = lang,
	z    = maketyped("bool"),
	u8   = maketyped("uint8_t"),
	u16  = maketyped("uint16_t"),
	u32  = maketyped("uint32_t"),
	u64  = maketyped("uint64_t"),
	i8   = maketyped("int8_t"),
	i16  = maketyped("int16_t"),
	i32  = maketyped("int32_t"),
	i64  = maketyped("int64_t"),
	f32  = maketyped("float"),
	f64  = maketyped("double"),
	__   = {}
}
