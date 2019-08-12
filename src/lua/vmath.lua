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
	-- Note: don't access bm8 in lua code, luajit has strict aliasing.
	-- Using bm8 for C calls is safe since luajit shouldn't be able to reorder accesses
	-- across C call boundaries.
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

local function maskf(f, xmask)
	if xmask then
		return function(bm8, n8, x)
			return f(bm8, n8, xmask(x))
		end
	else
		return f
	end
end

local function bitmapind(size, xmask)
	local set = maskf(C.bm_set64, xmask)
	return {
		init = function(self, pvec) self.n8 = self.n*size end,
		set  = function(self, x) set(self.bm8, self.n8, x) end,
		zero = function(self) C.bm_zero(self.bm8, self.n8) end,
		copy = function(self, other)
			assert(other.n8 == self.n8 and other ~= self)
			C.bm_copy(self.bm8, other.bm8, self.n8)
		end,
		not_ = function(self) C.bm_not(self.bm8, self.n8) end,
		and_ = bitmapop(maskf(C.bm_and64, xmask), C.bm_and),
		or_  = bitmapop(maskf(C.bm_or64, xmask),  C.bm_or),
		xor  = bitmapop(maskf(C.bm_xor64, xmask), C.bm_xor)
	}
end

ffi.metatype("struct Lbitmap_b8",  {__index=bitmapind(1, C.bmask8)})
ffi.metatype("struct Lbitmap_b16", {__index=bitmapind(2, C.bmask16)})
ffi.metatype("struct Lbitmap_b32", {__index=bitmapind(4, C.bmask32)})
ffi.metatype("struct Lbitmap_b64", {__index=bitmapind(8)})

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
