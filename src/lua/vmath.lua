local ffi = require "ffi"

-- XXX: this is a pretty ugly way to do this, these are (almost) exact copies of "struct pvec"
-- so that we can associate metatypes with them
ffi.cdef [[
	struct Lvec_f64 {
		type type;
		size_t n;
		vf64 *data;
	};
]]

local vf64 = {}

function vf64:add(x)
	if type(x) == "number" then
		ffi.C.vadd_f64(self.data, self.n, x)
	else
		assert(x.type == self.type and x.n == self.n)
		ffi.C.vadd2_f64(self.data, x.data, self.n)
	end
end

-- etc

ffi.metatype("struct Lvec_f64", {__index=vf64})

local function vec(pvec)
	if pvec.type == ffi.C.T_F64 then
		return ffi.cast("struct Lvec_f64 *", pvec)
	end

	assert(false)
end

return {
	vec=vec
}
