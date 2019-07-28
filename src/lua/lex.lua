local ffi = require "ffi"

local function frompvalue(pv, t)
	if t == ffi.C.PT_REAL then
		return pv.r
	elseif t == ffi.C.PT_INT then
		return pv.i
	elseif t == ffi.C.PT_BIT then
		return pv.b
	else
		assert("weird ptype: ", t)
	end
end

local function topvalue(val, t)
	local ret = ffi.new("pvalue")
	if t == ffi.C.PT_REAL then
		ret.r = val
	elseif t == ffi.C.PT_INT then
		ret.i = val
	elseif t == ffi.C.PT_BIT then
		ret.b = val
	end
	return ret
end

-- XXX: these should probable be C functions fromsimple & tosimple,
-- since the same conversion is also used when calling R (or other models)
local function frompvalue_s(pv, t)
	local ret = frompvalue(pv, t)
	if t == ffi.C.PT_BIT then
		ret = ffi.C.unpackenum(ret)
	end
	return ret
end

local function topvalue_s(val, t)
	if t == ffi.C.PT_BIT then
		val = ffi.C.packenum(val)
	end
	return topvalue(val, t)
end

return {
	frompvalue=frompvalue,
	topvalue=topvalue,
	frompvalue_s=frompvalue_s,
	topvalue_s=topvalue_s
}
