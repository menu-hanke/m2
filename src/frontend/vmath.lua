local alloc = require "alloc"
local code = require "code"
local ffi = require "ffi"
local C = ffi.C

-- memcmp needed for vector/bitmap equality testing
ffi.cdef [[ int memcmp ( const void *, const void *, size_t); ]]

-- small vector math library, design goals:
-- * integrate well with simulator, eg. do allocations from sim memory
-- * as little gc load as possible (this caused problem with the old implementation)
-- * try not to make traces too long (no complicated metatable tricks, this also caused problems
--   with the old implementation)
--
-- two ways to call the functions are offered:
--
-- * procedural-style:
--     vmath.mul(trees.ba, trees.f, #trees)
--     vmath.mul(trees.ba, 1/10000, #trees)
--
-- * oop-style:
--     local ba = vmath.real(trees.ba, #trees)
--     ba:mul(trees.f)
--     ba:mul(1/10000)

local vreal_size = ffi.sizeof("vreal")
local vreal_align = ffi.alignof("vreal")
local vreal_type = ffi.typeof("vreal")
local vptr_type = ffi.typeof("vreal *")
local vmask_size = ffi.sizeof("vmask")
local vmask_align = ffi.alignof("vmask")

--------------------------------------------------------------------------------

local function vecstr(data, n)
	local s = {}
	for i=0, tonumber(n)-1 do
		local sf = string.format("%010f", tonumber(data[i]))
		table.insert(s, sf)
	end
	return table.concat(s, "  ")
end

-- No need to check for double (or float) here, they will be "converted" to numbers before this
local function isscalar(x)
	return type(x) == "number"
end

local function overload2(scalarf, vectorf)
	return function(x, p, n, d)
		d = d or x
		if isscalar(p) then
			scalarf(d, x, p, n)
		else
			vectorf(d, x, p, n)
		end
	end
end

local function vsubc(d, x, c, n) C.vaddc(d, x, -c, n) end
local function vsubv(d, x, y, n) C.vaddsv(d, x, -1, y, n) end

local vmath_f = {
	----- real vectors -----
	set      = C.vsetc,
	add      = overload2(C.vaddc, C.vaddv),
	sub      = overload2(vsubc, vsubv),
	saddc    = function(x, a, b, n, d) C.vaddsc(d or x, a, x, b, n) end,
	adds     = function(x, a, y, n, d) C.vaddsv(d or x, x, a, y, n) end,
	mul      = overload2(C.vscale, C.vmulv),
	refl     = function(x, a, y, n, d) C.vrefl(d or x, a, x, y, n) end,
	area     = function(x, n, d) C.varead(d, x, n) end,
	sum      = C.vsum,
	summ     = C.vsumm,
	dot      = C.vdot,
	avgw     = C.vavgw,
	psumi    = function(x, idx, n, d) return (C.vpsumi(d, x,  idx, n)) end,
	psumim   = function(x, idx, m, mask, n, d) return (C.vpsumim(d, x, idx, m, mask, n)) end,
	copyvec  = function(dest, src, n) ffi.copy(dest, src, n*vreal_size) end,
	tostring = vecstr,

	---- bitmaps -----
	copybitmap = C.bm_copy,
	not_       = C.bm_not,
	and_       = C.bm_and,
	or_        = C.bm_or,
	xor        = C.bm_xor
}

--------------------------------------------------------------------------------

local function todata(x)
	-- TODO? maybe this should accept void pointers also
	return ffi.istype(vptr_type, x) and x or x.data
end

local function overload2v(scalarf, vectorf)
	return function(self, p, d)
		d = d and todata(d) or self.data

		if isscalar(p) then
			scalarf(d, self.data, p, self.n)
		else
			vectorf(d, self.data, todata(p), self.n)
		end
	end
end

local vecm_ct = ffi.metatype([[
	struct {
		vreal *data;
		vmask *m;
		vmask mask;
		size_t n;
	}]], {
	
	__index = {
		sum   = function(self) return (C.vsumm(self.data, self.m, self.mask, self.n)) end,
		psumi = function(self, dest, idx)
			return (C.vpsumim(todata(dest), self.data, idx, self.m, self.mask, self.n))
		end
	}
})

local vec_ct = ffi.metatype([[
	struct {
		vreal *data;
		size_t n;
	}]], {

	__index = {
		set   = function(self, c) C.vsetc(self.data, c, self.n) end,
		add   = overload2v(C.vaddc, C.vaddv),
		sub   = overload2v(vsubc, vsubv),
		saddc = function(self, a, b, d)
			vmath_f.saddc(self.data, a, b, self.n, d and todata(d))
		end,
		adds  = function(self, a, y, d)
			vmath_f.adds(self.data, a, todata(y), self.n, d and todata(d))
		end,
		mul   = overload2v(C.vscale, C.vmulv),
		refl  = function(self, a, y, d)
			vmath_f.refl(self.data, a, todata(y), self.n, d and todata(d))
		end,
		area  = function(self, d) C.varead(self.data, todata(d), self.n) end,
		sum   = function(self) return (C.vsum(self.data, self.n)) end,
		dot   = function(self, y) return (C.vdot(self.data, todata(y), self.n)) end,
		avgw  = function(self, w) return (C.vavgw(self.data, todata(w), self.n)) end,
		psumi = function(self, dest, idx)
			return (C.vpsumi(todata(dest), self.data, idx, self.n))
		end,
		mask  = function(self, mask, m) return (vecm_ct(self.data, mask, m, self.n)) end
	},

	__tostring = function(self) return vecstr(self.data, self.n) end,
	__len = function(self) return tonumber(self.n) end,
	__eq = function(self, other)
		return C.memcmp(self.data, todata(other), self.n*vreal_size) ~= 0
	end
})

vmath_f.vec = vec_ct
vmath_f.vecm = vecm_ct

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
local function ismask(x)
	return type(x) == "number" or ffi.istype(mask_type, x)
end

local function overload2b(maskf, bitmapf)
	return function(self, x)
		if ismask(x) then
			maskf(self.bitmap, self.n8, x)
		else
			bitmapf(self.bitmap, tobitmap(x))
		end
	end
end

local function masked(f, size)
	if size == 8 then
		return f
	end

	local mask = ({[1]=C.bmask8, [2]=C.bmask16, [4]=C.bmask32})[size]
	return function(bm8, n8, x)
		return f(bm8, n8, mask(x))
	end
end

local function bm8_ct(size)
	local set64 = masked(C.bm_set64, size)

	return ffi.metatype([[
		struct {
			bm8 *bitmap;
			size_t n;
		}]], {
		
		__index = {
			set   = function(self, x) set64(self.bitmap, self.n, x) end,
			zero  = function(self) C.bm_zero(self.bitmap, self.n) end,
			not_  = function(self) C.bm_not(self.bitmap, self.n) end,
			and_  = overload2b(masked(C.bm_and64, size), C.bm_and),
			or_   = overload2b(masked(C.bm_or64,  size), C.bm_or),
			xor   = overload2b(masked(C.bm_xor64, size), C.bm_xor)
		},

		__tostring = function(self) return bitmapstr(self.data, self.n/size, size) end,
		__len = function(self) return tonumber(self.n/size) end,
		__eq = function(self, other)
			return C.memcmp(self.bitmap, other.bitmap, self.n) ~= 0
		end
	})
end

local bitmap_ct = setmetatable({}, {
	__index = function(self, size)
		self[size] = bm8_ct(size)
		return self[size]
	end
})

-- there's probably a better way to do this (but it's not with a table lookup as cdata can't
-- be used for table keys)
local function bitmap_size(data)
	-- this is the fast path which is almost always taken
	if ffi.istype("uint64_t *", data) then return 8 end

	if ffi.istype("uint32_t *", data) then return 4 end
	if ffi.istype("uint16_t *", data) then return 2 end
	if ffi.istype("uint8_t  *", data) then return 1 end
end

function vmath_f.bitmap(data, n)
	local ct = bitmap_ct[bitmap_size(data)]
	return ct(ffi.cast("bm8 *", data), n)
end

--------------------------------------------------------------------------------

local function freevec(v)
	C.free(v.data)
end

local function allocvec(n)
	local data = alloc.malloc_nogc(vreal_type, n, vptr_type)
	return ffi.gc(vec_ct(data, n), freevec)
end

--------------------------------------------------------------------------------

local loop_mt = { __index={} }

local function defloop(n, wrap)
	local vnames = {}
	local vidx = {}

	for i=1, n do
		vnames[i] = "___v"..i
		vidx[i] = (wrap and vnames[i]..".data" or vnames[i]).."[___i]"
	end

	vnames = table.concat(vnames, ",")
	vidx = table.concat(vidx, ",")

	return function(loop)
		return string.format([[
			function(%s, %s ___state)
				%s
				for ___i=0, %s do
					%s
				end
				%s
			end
		]], vnames, wrap and "" or "n,",
		loop.preloop(),
		wrap and "#___v1-1" or "n-1",
		loop.body(vidx .. ", ___state"), loop.postloop())
	end
end

local function loop(loopfunc, ...)
	if type(loopfunc) == "number" then
		loopfunc = defloop(loopfunc, ...)
	end

	return setmetatable({
		loopfunc  = loopfunc,
		value     = "%s",
		code      = code.new(),
		upvalues  = {},
	}, loop_mt)
end

function loop_mt.__index:map(f)
	local name = "___map"..#self.code
	self.code:emitf("local %s = %s", name, name)
	self.upvalues[name] = f
	self.value = string.format("%s(%s)", name, self.value)
	return self
end

function loop_mt.__index:reduce(f, ...)
	local name = "___reduce"..#self.code
	self.code:emitf("local %s = %s", name, name)
	self.upvalues[name] = f

	local init = {...}
	local rvs = {}
	for i,v in ipairs(init) do
		local ivname = "___reduce_init"..i
		self.code:emitf("local %s = %s", ivname, ivname)
		self.upvalues[ivname] = v
		table.insert(rvs, "___r"..i)
	end

	rvs = table.concat(rvs, ", ")

	self.code:emitf("return %s", self.loopfunc {

		preloop = function()
			local ret = {}
			for i=1, #rvs do
				table.insert(ret, string.format("local ___r%d = ___reduce_init%d", i, i))
			end
			return table.concat(ret, "\n")
		end,

		body = function(iv)
			iv = string.format(self.value, iv)
			return string.format("%s = %s(%s, %s)", rvs, name, rvs, iv)
		end,

		postloop = function()
			return string.format("return  %s", rvs)
		end

	})

	return self:compile()
end

function loop_mt.__index:sum()
	return self:reduce(function(a, b) return a+b end, 0)
end

function loop_mt.__index:dot2()
	return self:reduce(function(r, a, b) return r+a*b end, 0)
end

function loop_mt.__index:compile()
	return self.code:compile(self.upvalues, string.format("=(loop@%p)", self))()
end

--------------------------------------------------------------------------------

local vmexpand = { [4]=C.vmexpand32, [2]=C.vmexpand16, [1]=C.vmexpand8 }
local function inject(env)
	local _sim = env.sim

	env.m2.vmath = setmetatable({

		loop   = loop,

		-- sorti(data, n [,dest [,life]])
		sorti  = function(data, n, dest, life)
			dest = dest or ffi.cast("unsigned *",
				C.sim_alloc(_sim, vreal_size*n, vreal_align, life or C.SIM_FRAME))
			C.vsorti(dest, data, n)
			return dest
		end,

		-- vsorti(vec [,dest [,life]])
		vsorti = function(vec, dest, life)
			return env.m2.vmath.sorti(vec.data, vec.n, dest, life)
		end,

		-- mask(data, n [,size [,dest [,life]]])
		mask   = function(data, n, size, dest, life)
			size = size or bitmap_size(data) or
				error(string.format("Not a bitmap type: '%s'", data))

			if size < vmask_size then
				dest = dest or C.sim_alloc(_sim, vmask_size*n, vmask_align, life or C.SIM_FRAME)
				vmexpand[size](dest, data, n)
				return dest
			end

			return data
		end

	}, { __index = vmath_f })

	-- Note: maybe add a function to alloc from sim pool instead if malloc is too slow
	env.m2.allocv = allocvec
	-- allocbitmap?
end

return {
	vmath_f   = vmath_f,
	allocvec  = allocvec,
	inject    = inject
}
