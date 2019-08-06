local ffi = require "ffi"
local C = ffi.C

local builtin_types = {
	f32 = C.T_F32,
	f64 = C.T_F64,
	b8  = C.T_B8,
	b16 = C.T_B16,
	b32 = C.T_B32,
	b64 = C.T_B64,
	z   = C.T_POSITION
}

local tvalue_map = {}
for k,v in pairs(builtin_types) do
	tvalue_map[tonumber(v)] = k
end

local pvalue_map = {
	[tonumber(C.PT_REAL)] = "r",
	[tonumber(C.PT_BIT)]  = "b",
	[tonumber(C.PT_POS)]  = "p"
}

local function lua2tvalue(v, t)
	local ret = ffi.new("tvalue")
	ret[tvalue_map[tonumber(t)]] = v
	return ret
end

local function tvalue2lua(tv, t)
	return tonumber(tv[builtin_types[tonumber(t)]])
end

return {
	lua2tvalue    = lua2tvalue,
	tvalue2lua    = tvalue2lua,
	builtin_types = builtin_types
}
