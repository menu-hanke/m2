local typing = require "typing"
local ffi = require "ffi"
local C = ffi.C

local bitmap_types = {
	b8  = "uint8_t",
	b16 = "uint16_t",
	b32 = "uint32_t",
	b64 = "uint64_t"
}

ffi.cdef [[
	struct Lvec {
		size_t n;
		vreal *data;
	};

	struct Lvec_masked {
		size_t n;
		vreal *data;
		vmask *mask;
		vmask m;
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
			dest = self.data
		end

		if type(x) == "number" then
			scalarf(dest, self.data, x, self.n)
		else
			vectorf(dest, self.data, x, self.n)
		end
	end
end

------------------------

ffi.metatype("struct Lvec", { __index = {
	set   = function(self, c) C.vsetc(self.data, c, self.n) end,
	add   = vbinop(C.vaddc, C.vaddv),
	mul   = vbinop(C.vmulc, C.vmulv),
	area  = function(self, dest) C.varead(dest, self.data, self.n) end,
	sorti = function(self)
		-- TODO: this allocation is NYI, use arena etc.
		local ret = ffi.new("unsigned[?]", self.n)
		C.vsorti(ret, self.data, self.n)
		return ret
	end,
	mask  = function(self, mask, m)
		local ret = ffi.new("struct Lvec_masked")
		ret.n = self.n
		ret.data = self.data
		ret.mask = mask
		ret.m = m
		return ret
	end,
	sum   = function(self) return (C.vsum(self.data, self.n)) end,
	psumi = function(self, dest, idx) return (C.vpsumi(dest, self.data, idx, self.n)) end
}})

ffi.metatype("struct Lvec_masked", { __index = {
	sum   = function(self) return C.vsumm(self.data, self.mask. self.m, self.n) end,
	psumi = function(self, dest, idx)
		return (C.vpsumim(dest, self.data, idx, self.mask, self.m, self.n))
	end
}})

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

local function bitmapind(size, xmask, expand)
	local set = maskf(C.bm_set64, xmask)
	local vmask

	if size == ffi.sizeof("vmask") then
		vmask = function(self) return self.data end
	elseif expand then
		vmask = function(self)
			-- TODO: NYI, replace with sim alloc
			local ret = ffi.new("vmask[?]", self.n)
			expand(ret, self.data, self.n)
			return ret
		end
	end

	return {
		init  = function(self) self.n8 = self.n*size end,
		set   = function(self, x) set(self.bm8, self.n8, x) end,
		zero  = function(self) C.bm_zero(self.bm8, self.n8) end,
		copy  = function(self, other)
			assert(other.n8 == self.n8 and other ~= self)
			C.bm_copy(self.bm8, other.bm8, self.n8)
		end,
		vmask = vmask,
		not_  = function(self) C.bm_not(self.bm8, self.n8) end,
		and_  = bitmapop(maskf(C.bm_and64, xmask), C.bm_and),
		or_   = bitmapop(maskf(C.bm_or64, xmask),  C.bm_or),
		xor   = bitmapop(maskf(C.bm_xor64, xmask), C.bm_xor)
	}
end

ffi.metatype("struct Lbitmap_b8",  {__index=bitmapind(1, C.bmask8,  C.vmexpand8)})
ffi.metatype("struct Lbitmap_b16", {__index=bitmapind(2, C.bmask16, C.vmexpand16)})
ffi.metatype("struct Lbitmap_b32", {__index=bitmapind(4, C.bmask32, C.vmexpand32)})
ffi.metatype("struct Lbitmap_b64", {__index=bitmapind(8)})

------------------------

local bitmaps = {
	[tonumber(ffi.C.T_B8)]  = "struct Lbitmap_b8",
	[tonumber(ffi.C.T_B16)] = "struct Lbitmap_b16",
	[tonumber(ffi.C.T_B32)] = "struct Lbitmap_b32",
	[tonumber(ffi.C.T_B64)] = "struct Lbitmap_b64"
}

local function vec(data, n)
	local ret = ffi.new("struct Lvec")
	ret.data = data
	ret.n = n
	return ret
end

local function bitmap(type, data, n)
	local t = bitmaps[tonumber(type.desc)]
	-- TODO: the union here causes NYI
	local ret = ffi.new(t)
	ret.data = data
	ret.n = n
	ret:init()
	return ret
end

local function typed(type, data, n)
	if typing.promote(type.desc) == ffi.C.T_B64 then
		return bitmap(type, data, n)
	elseif type.desc == typing.builtin_types.real.desc then
		return vec(data, n)
	end
end

return {
	vec    = vec,
	bitmap = bitmap,
	typed  = typed
}
