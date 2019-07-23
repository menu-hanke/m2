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

return {
	frompvalue=frompvalue,
	topvalue=topvalue
}
