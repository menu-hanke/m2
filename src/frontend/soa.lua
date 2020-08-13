-------- struct-of-arrays (see vec.c) --------------------

require "alloc"
local misc = require "misc"
local reflect = require "lib.reflect"
local ffi = require "ffi"
local C = ffi.C

local vec_ctp = ffi.typeof("struct vec *")

local function ctbands(refct)
	local band_start = ffi.offsetof("struct vec", "bands")
	return coroutine.wrap(function()
		for memb in refct:members() do
			if memb.offset >= band_start then
				local idx = (memb.offset - band_start) / ffi.sizeof("void *")
				coroutine.yield(memb, idx)
			end
		end
	end)
end

-- Note: by setting this metatype, you bind the ctype to the simulator, ie. you can't use
-- the same ctype with another _sim instance (probably won't be a problem, I can't think why
-- you would want more than one _sim instance.)
local function refvec_mt(_sim, ctype, info, slicect)
	local refct = reflect.typeof(ctype)
	local band_stride = {}

	-- skip info, n_alloc, n_used
	for memb, idx in ctbands(refct) do
		band_stride[memb.name] = info.stride[idx]
	end

	local ctp = ffi.typeof("$*", ctype)

	return {

		__index = {

			new  = function()
				return ffi.cast(ctp, C.simL_vec_create(_sim, info, C.SIM_VSTACK))
			end,

			alloc = function(self, n)
				return (tonumber(C.simF_vec_alloc(_sim, ffi.cast(vec_ctp, self), n)))
			end,

			newband = function(self, name)
				local old = self[name]
				local vp = ffi.cast(vec_ctp, self)
				self[name] = C.simF_vec_create_band_stride(
					_sim,
					ffi.cast(vec_ctp, self),
					band_stride[name]
				)
				return self[name], old
			end,

			xnewband = function(self, name)
				return ffi.cast(ffi.typeof(self[name]), C.simF_vec_create_band_stride(
					_sim,
					ffi.cast(vec_ctp, self),
					band_stride[name]
				))
			end,

			delete = function(self, idx, n)
				if type(idx) == "table" then
					-- TODO: alloc this on sim ephemeral region when
					n = #idx
					if n == 0 then return end
					local idx_ = ffi.new("unsigned[?]", n)
					for i=1, n do
						idx_[i-1] = idx[i]
					end
					idx = idx_
				end

				C.simF_vec_delete(_sim, ffi.cast(vec_ctp, self), n, idx)
			end,

			clear = function(self)
				C.vec_clear(ffi.cast(vec_ctp, self))
			end,

			-- optional
			slice = slicect
		},

		__len = function(self)
			return ffi.cast(vec_ctp, self).n_used
		end

	}
end

local function refproto(alloc, ctype)
	local refct = reflect.typeof(ctype)
	local stride = {}
	local nb = 0

	for memb, idx in ctbands(refct) do
		stride[idx] = memb.type.element_type.size
		nb = nb+1
	end

	-- TODO: probably would be cleaner to make a vec_info_size(...) function in C
	local proto = ffi.cast("struct vec_info *", alloc(
		ffi.sizeof("struct vec_info") + nb*ffi.sizeof("uint16_t"),
		ffi.alignof("struct vec_info")
	))

	proto.n_bands = nb
	for i=0, nb-1 do
		proto.stride[i] = stride[i]
	end

	return proto
end

-- use this on a customized slice type, ie.
--     struct my_slice {
--         my_vec *vp;
--         uint32_t from, to;
--     }
local slice_mt = {
	__len = function(self) return self.___to - self.___from end,
	__index = function(self, k) return self.___vec[k] + self.___from end
}

local function slicectof(ctype)
	return ffi.metatype(ffi.typeof("struct { $ *vec; uint32_t from, to; }", ctype), slice_mt)
end

-- in:  {band1="double", band2="float", ..., bandN=ffi.typeof("mytype")}
-- out: ffi.typeof [[
--     struct {
--		   struct vec ___v;
--		   double *band1;
--		   float *band2;
--		   ...
--		   mytype *bandN;
--     }
-- ]]
--
-- Note: order of fields is undefined!
local function ctfrombands(bands)
	local buf, ctypes = {}, {}

	for name,ctype in pairs(bands) do
		table.insert(buf, string.format("$ *%s;", name))
		table.insert(ctypes, ffi.typeof(ctype))
	end

	return ffi.typeof(string.format([[
		struct {
			struct vec ___v;
			%s
		}
	]], table.concat(buf, "")), unpack(ctypes))
end

-- vec_loop(band1, band2, ..., bandN)
-- for use with vmath.loop()
local function vec_loop(...)
	local bandidx = {}
	for i,v in ipairs({...}) do
		bandidx[i] = string.format("vec['%s'][___i]", v)
	end
	bandidx = table.concat(bandidx, ", ")

	return function(loop)
		return string.format([[
		function(vec, ___state)
			%s
			for ___i=0, #vec-1 do
				%s
			end
			%s
		end
		]], loop.preloop(), loop.body(bandidx .. ", ___state"), loop.postloop())
	end
end

----------------------------------------

local function mt_merge(meta, mt)
	local m = {}
	for k,v in pairs(mt) do m[k] = v end
	for k,v in pairs(meta) do m[k] = v end

	if meta.__index then
		if type(meta.__index) ~= "table" then
			error("non-table __index")
		end

		local index = {}
		for k,v in pairs(mt.__index) do index[k] = v end
		for k,v in pairs(meta.__index) do index[k] = v end

		m.__index = index
	else
		m.__index = mt.__index
	end

	return m
end

local function inject(env)
	local _sim = env.sim

	local function reflct(ctype, info, slicect)
		if not info then
			-- TODO: sim allocator
			info = refproto(_sim:allocator("static"), ctype)
		end

		if not slicect then
			slicect = slicectof(ctype)
		end

		local mt = refvec_mt(_sim, ctype, info, slicect)
		return mt, info, slicect
	end
	
	env.m2.soa = {
		loop        = vec_loop,
		reflect     = reflct,

		from_bands  = function(bands, meta)
			local ct = ctfrombands(bands)
			local mt, info, slicect = reflct(ct)
			if meta then mt = mt_merge(meta, mt) end
			ffi.metatype(ct, mt)
			return ct, info, slicect
		end
	}

	env.m2.new_soa = function(x)
		if ffi.istype("struct vec_info *", x) then
			return C.simL_vec_create(_sim, x, C.SIM_VSTACK)
		else
			return x.new()
		end
	end

end

return {
	inject = inject
}
