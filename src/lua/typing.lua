local ffi = require "ffi"
local C = ffi.C

local builtin_types = {
	f32 = C.T_F32,
	f64 = C.T_F64,
	b8  = C.T_B8,
	b16 = C.T_B16,
	b32 = C.T_B32,
	b64 = C.T_B64,
	b   = C.T_BOOL,
	id  = C.T_ID,
	z   = C.T_POSITION,
	u   = C.T_USERDATA
}

local convert_number = {
	f32 = true,
	f64 = true
}

local tvalue_map = {}
for k,v in pairs(builtin_types) do
	tvalue_map[tonumber(v)] = k
end

local pvalue_map = {
	[tonumber(C.PT_REAL)]   = "r",
	[tonumber(C.PT_BIT)]    = "b",
	[tonumber(C.PT_BOOL)]   = "b",
	[tonumber(C.PT_ID)]     = "id",
	[tonumber(C.PT_POS)]    = "z",
	[tonumber(C.PT_UDATA)]  = "u"
}

local function lua2tvalue(v, t)
	local ret = ffi.new("tvalue")
	ret[tvalue_map[tonumber(t)]] = v
	return ret
end

local function tvalue2lua(tv, t)
	t = tonumber(t)
	local ret = tv[tvalue_map[t]]
	-- this check is mainly to prevent the number conversion from destroying my pointers
	if convert_number[t] then
		ret = tonumber(ret)
	end
	return ret
end

local function lua2pvalue(v, t)
	return C.vpromote(lua2tvalue(v, t), t)
end

local function pvalue2lua(pv, t)
	return tvalue2lua(C.vdemote(pv, t), t)
end

local function out2sim(x, t)
	if C.tpromote(t) == C.PT_BIT then
		x = C.packenum(x)
	end

	return x
end

local function sim2out(x, t)
	if C.tpromote(t) == C.PT_BIT then
		x = C.unpackenum(x)
	end

	return x
end

return {
	lua2tvalue    = lua2tvalue,
	tvalue2lua    = tvalue2lua,
	lua2pvalue    = lua2pvalue,
	pvalue2lua    = pvalue2lua,
	out2sim       = out2sim,
	sim2out       = sim2out,
	builtin_types = builtin_types,
	pvalue_map    = pvalue_map
}
