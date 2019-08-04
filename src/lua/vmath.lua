local ffi = require "ffi"
local C = ffi.C

-- XXX: this is a pretty ugly way to do this, these are (almost) exact copies of "struct pvec"
-- so that we can associate metatypes with them
ffi.cdef [[
	struct Lvec_f64 {
		type type;
		size_t n;
		vf64 *data;
	};
]]

------------------------

local function vbinop(scalarf, vectorf)
	return function(self, x, dest)
		if not dest then
			dest = self
		end

		assert(self.type == dest.type and self.n == dest.n)

		if type(x) == "number" then
			scalarf(dest.data, self.data, x, self.n)
		else
			assert(x ~= self and x.type == self.type and x.n == self.n)
			vectorf(dest.data, self.data, x.data, self.n)
		end
	end
end

------------------------

local vf64 = {
	set = function(self, c) C.vset_f64(self.data, c, self.n) end,
	add = vbinop(C.vadd_f64s, C.vadd_f64v)
}

ffi.metatype("struct Lvec_f64", {__index=vf64})

------------------------

local function vec(pvec)
	if pvec.type == ffi.C.T_F64 then
		return ffi.cast("struct Lvec_f64 *", pvec)
	end

	assert(false)
end

return {
	vec=vec
}
