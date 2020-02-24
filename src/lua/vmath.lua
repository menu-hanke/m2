local typing = require "typing"
local alloc = require "alloc"
local kernel = require "kernel"
local ffi = require "ffi"
local C = ffi.C

local Tvec = ffi.typeof [[
	struct {
		size_t n;
		vreal *data;
	}
]]

local Tvec_masked = ffi.typeof [[
	struct {
		size_t n;
		vreal *data;
		vmask *mask;
		vmask m;
	}
]]

local function bitmap_type(ctype)
	-- This struct is a hack to make luajit happy, the bm8 and uint*_t pointers always
	-- point to the same data but the bm8 is used for C calls.
	-- Absolutely don't access the bm8 pointer in lua code, this breaks strict aliasing.
	-- It's fine to pass it to C since luajit can't reorder writes/reads accross the
	-- call boundary.
	-- Ideally we would only have a single pointer here but this is preferable to
	-- spamming ffi.cast
	return ffi.typeof(string.format([[
		struct {
			size_t n;
			size_t n8;
			bm8 *bm8;
			%s *data;
		}
	]], ctype))
end

local Tbitmaps = {
	[tonumber(ffi.C.T_B8)]  = bitmap_type("uint8_t"),
	[tonumber(ffi.C.T_B16)] = bitmap_type("uint16_t"),
	[tonumber(ffi.C.T_B32)] = bitmap_type("uint32_t"),
	[tonumber(ffi.C.T_B64)] = bitmap_type("uint64_t")
}

--------------------------------------------------------------------------------

local function vecstr(data, n)
	local s = {}
	for i=0, tonumber(n)-1 do
		local sf = string.format("%010f", tonumber(data[i]))
		table.insert(s, sf)
	end
	return table.concat(s, "  ")
end

local vreal_type = ffi.typeof("vreal")
local function isscalar(x)
	return type(x) == "number" or ffi.typeof(x) == vreal_type
end

local vptr_type = ffi.typeof("vreal *")
local function todata(x)
	-- TODO? maybe this should accept void pointers also
	return ffi.typeof(x) == vptr_type and x or x.data
end

local function vbinop(scalarf, vectorf)
	return function(self, x, dest)
		dest = dest and todata(dest) or self.data

		if isscalar(x) then
			scalarf(dest, self.data, x, self.n)
		else
			x = todata(x)
			assert(dest ~= x)
			vectorf(dest, self.data, todata(x), self.n)
		end
	end
end

------------------------

local function vsubc(d, x, c, n) C.vaddc(d, x, -c, n) end
local function vsubv(d, x, y, n) C.vaddsv(d, x, -1, y, n) end
local vreal_size = ffi.sizeof("vreal")

ffi.metatype(Tvec, {
	__index = {
		set   = function(self, c) C.vsetc(self.data, c, self.n) end,
		add   = vbinop(C.vaddc, C.vaddv),
		saddc = function(self, a, b, dest)
			C.vsaddc(dest and todata(dest) or self.data, a, self.data, b, self.n)
		end,
		adds  = function(self, a, y, dest)
			C.vaddsv(dest and todata(dest) or self.data, self.data, a, todata(y), self.n)
		end,
		sub   = vbinop(vsubc, vsubv),
		mul   = vbinop(C.vscale, C.vmulv),
		refl  = function(self, a, y, dest)
			C.vrefl(dest and todata(dest) or self.data, a, self.data, todata(y), self.n)
		end,
		area  = function(self, dest) C.varead(todata(dest), self.data, self.n) end,
		sorti = function(self, dest)
			-- TODO: this allocation is NYI, use arena etc.
			dest = dest or ffi.new("unsigned[?]", self.n)
			C.vsorti(dest, self.data, self.n)
			return dest
		end,
		mask  = function(self, mask, m) return Tvec_masked(self.n, self.data, mask, m) end,
		sum   = function(self) return (C.vsum(self.data, self.n)) end,
		dot   = function(self, y) return (C.vdot(self.data, todata(y), self.n)) end,
		avgw  = function(self, w) return (C.vavgw(self.data, todata(w), self.n)) end,
		psumi = function(self, dest, idx) return (C.vpsumi(todata(dest), self.data, idx, self.n)) end,
		copy  = function(self, dest) ffi.copy(todata(dest), self.data, self.n*vreal_size) end
	},

	__tostring = function(self) return vecstr(self.data, self.n) end,
	__len = function(self) return tonumber(self.n) end
})

ffi.metatype(Tvec_masked, { __index = {
	sum   = function(self) return C.vsumm(self.data, self.mask, self.m, self.n) end,
	psumi = function(self, dest, idx)
		return (C.vpsumim(todata(dest), self.data, idx, self.mask, self.m, self.n))
	end
}})

--------------------------------------------------------------------------------

local function binarystr(d, n)
	local bs = {}

	for i=1, n do
		bs[i] = (d%2 == 1) and "1" or "0"
		d = d / 2ULL
	end

	return table.concat(bs, "")
end

local function bitmapstr(data, n, size)
	size = size or 8
	local chunks = {}

	for i=0, tonumber(n)-1 do
		chunks[i+1] = binarystr(data[i], size)
	end

	return table.concat(chunks, "\t")
end

local mask_type = ffi.typeof("uint64_t")
local function isscalarmask(x)
	return type(x) == "number" or ffi.typeof(x) == mask_type
end

local function bitmapop(maskf, bitmapf)
	return function(self, x)
		if isscalarmask(x) then
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

local function bitmapmt(size, xmask, expand)
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
		__index = {
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
		},
		
		__tostring = function(self) return bitmapstr(self.data, self.n, size) end,
		__len = function(self) return tonumber(self.n) end
	}
end

ffi.metatype(Tbitmaps[tonumber(ffi.C.T_B8)],  bitmapmt(1, C.bmask8,  C.vmexpand8))
ffi.metatype(Tbitmaps[tonumber(ffi.C.T_B16)], bitmapmt(2, C.bmask16, C.vmexpand16))
ffi.metatype(Tbitmaps[tonumber(ffi.C.T_B32)], bitmapmt(4, C.bmask32, C.vmexpand32))
ffi.metatype(Tbitmaps[tonumber(ffi.C.T_B64)], bitmapmt(8))

------------------------

local function freevec(v)
	C.free(v.data)
end

local function allocvec(n)
	local data = alloc.malloc_nogc(vreal_type, n, vptr_type)
	return ffi.gc(Tvec(n, data), freevec)
end

local function bitmap(desc, data, n)
	local ret = Tbitmaps[desc]()
	ret.data = data
	ret.bm8 = ffi.cast("bm8 *", data)
	ret.n = n
	ret:init()
	return ret
end

local real_desc = typing.builtin_types.real.desc
local promote = typing.promote
local function typed(desc, data, n)
	if desc == real_desc then
		return Tvec(n, data)
	elseif promote(desc) == C.T_B64 then
		return bitmap(desc, data, n)
	end
end

--------------------------------------------------------------------------------

local function vec_loop(n)
	n = n or 1

	local vnames = {}
	local vidx = {}

	for i=1, n do
		vnames[i] = "___v"..i
		vidx[i] = vnames[i]..".data[___i]"
	end

	vnames = table.concat(vnames, ",")
	vidx = table.concat(vidx, ",")

	return {
		signature = string.format("return function(%s, ___state)", vnames),
		header    = "for ___i=0, #___v1-1 do",
		init      = string.format("%s, ___state", vidx)
	}
end

local function inject(env)
	-- Note: maybe add a function to alloc from sim pool instead if malloc is too slow
	env.m2.allocv = allocvec
	env.m2.kernel.vec = function(n) return kernel.create(vec_loop(n)) end
	-- allocbitmap?
end

return {
	allocvec  = allocvec,
	vecstr    = vecstr,
	bitmapstr = bitmapstr,
	typed     = typed,
	todata    = todata,
	inject    = inject
}
