local ffi = require "ffi"
local C = ffi.C

local fftypes = {
	[tonumber(ffi.typeof "bool")]     = "z",
	[tonumber(ffi.typeof "uint8_t")]  = "u8",
	[tonumber(ffi.typeof "uint16_t")] = "u16",
	[tonumber(ffi.typeof "uint32_t")] = "u32",
	[tonumber(ffi.typeof "uint64_t")] = "u64",
	[tonumber(ffi.typeof "int8_t")]   = "i8",
	[tonumber(ffi.typeof "int16_t")]  = "i16",
	[tonumber(ffi.typeof "int32_t")]  = "i32",
	[tonumber(ffi.typeof "int64_t")]  = "i64",
	[tonumber(ffi.typeof "float")]    = "f32",
	[tonumber(ffi.typeof "double")]   = "f64",
}

local function has(lang)
	return pcall(function() return C["fff"..lang.."_call"] end)
end

local function fftype(edge)
	local t = fftypes[tonumber(edge.ctype)] or error(string.format("non-scalar ctype: %s", edge.ctype))
	if not edge.scalar then
		t = t:upper()
	end
	return t
end

local function signature(signature)
	local out = {}
	for _,p in ipairs(signature.params) do
		table.insert(out, fftype(p))
	end
	table.insert(out, ">")
	for _,r in ipairs(signature.returns) do
		table.insert(out, fftype(r))
	end
	return table.concat(out, " ")
end

local function raise(F, clear)
	local ecode = C.fff_ecode(F)
	local emsg = ffi.string(C.fff_errmsg(F))
	if clear then
		C.fff_clear_error(F)
	end
	error(string.format("fff error (%d): %s", ecode, emsg))
end

local function checkerr(F, clear)
	if C.fff_ecode(F) ~= 0 then
		raise(F, clear)
	end
end

ffi.metatype("fff_state", {
	__index = {
		raise    = raise,
		checkerr = checkerr
	}
})

local function state()
	return ffi.gc(C.fff_create(), C.fff_destroy)
end

return {
	has       = has,
	fftype    = fftype,
	signature = signature,
	checkerr  = checkerr,
	state     = state
}
