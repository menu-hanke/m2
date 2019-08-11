local ffi = require "ffi"
local C = ffi.C

local bitmap_types = {
	b8  = "uint8_t",
	b16 = "uint16_t",
	b32 = "uint32_t",
	b64 = "uint64_t"
}

ffi.cdef [[
	struct Lvec_f64 {
		size_t n;
		vf64 *data;
	};
]]

for b,t in pairs(bitmap_types) do
	ffi.cdef(string.format([[
		struct Lbitmap_%s {
			size_t n;
			size_t n8;
			union {
				bm8 *bm8;
				%s *data;
			};
		}
	]], b, t))
end

------------------------

local function vbinop(scalarf, vectorf)
	return function(self, x, dest)
		if not dest then
			dest = self
		end

		assert(getmetatable(self) == getmetatable(dest) and self.n == dest.n)

		if type(x) == "number" then
			scalarf(dest.data, self.data, x, self.n)
		else
			assert(x ~= self and getmetatable(x) == getmetatable(self) and x.n == self.n)
			vectorf(dest.data, self.data, x.data, self.n)
		end
	end
end

------------------------

local vf64 = {
	init = function() end,
	set = function(self, c) C.vset_f64(self.data, c, self.n) end,
	add = vbinop(C.vadd_f64s, C.vadd_f64v)
}

ffi.metatype("struct Lvec_f64", {__index=vf64})

------------------------

local function bitmapop(maskf, bitmapf)
	return function(self, x)
		if type(x) == "number" then
			maskf(self.bm8, self.n8, x)
		else
			assert(x ~= self and x.n == self.n and x.n8 == self.n8)
			bitmapf(self.bm8, x.bm8, self.n8)
		end
	end
end

------------------------

local bitmap_size = {
	[tonumber(ffi.C.T_B8)]  = 1,
	[tonumber(ffi.C.T_B16)] = 2,
	[tonumber(ffi.C.T_B32)] = 3,
	[tonumber(ffi.C.T_B64)] = 4
}

local bitmap = {
	init = function(self, pvec) self.n8 = self.n*bitmap_size[tonumber(pvec.type)] end,
	zero = function(self) C.bm_zero(self.bm8, self.n8) end,
	copy = function(self, other)
		assert(other.n8 == self.n8 and other ~= self)
		C.bm_copy(self.bm8, other.bm8, self.n8)
	end,
	not_ = function(self) C.bm_not(self.bm8, self.n8) end,
	and_ = bitmapop(C.bm_and, C.bm_and2),
	or_  = bitmapop(C.bm_or,  C.bm_or2),
	xor  = bitmapop(C.bm_xor, C.bm_xor2)
}

local bitmap_mt = {__index=bitmap}
ffi.metatype("struct Lbitmap_b8", bitmap_mt)
ffi.metatype("struct Lbitmap_b16", bitmap_mt)
ffi.metatype("struct Lbitmap_b32", bitmap_mt)
ffi.metatype("struct Lbitmap_b64", bitmap_mt)

------------------------

local vtypes = {
	[tonumber(ffi.C.T_F64)] = "struct Lvec_f64",
	[tonumber(ffi.C.T_B8)]  = "struct Lbitmap_b8",
	[tonumber(ffi.C.T_B16)] = "struct Lbitmap_b16",
	[tonumber(ffi.C.T_B32)] = "struct Lbitmap_b32",
	[tonumber(ffi.C.T_B64)] = "struct Lbitmap_b64"
}

local function vec(pvec)
	local t = vtypes[tonumber(pvec.type)]
	local ret = ffi.new(t)
	ret.n = pvec.n
	ret.data = pvec.data
	ret:init(pvec)
	return ret
end

return {
	vec=vec
}
