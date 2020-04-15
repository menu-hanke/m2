local ffi = require "ffi"
local typing = require "typing"
local fhk = require "fhk"
local kernel = require "kernel"
local C = ffi.C

local vec_mt = { __len = function(self) return self.___nused end }
local slice_mt = { __len = function(self) return self.to - self.from end }

local vec_ctp = ffi.typeof("struct vec *")

local function genvectypes(sim, typ)
	-- Note: this might not be completely safe and it's definitely not defined behavior by C
	-- standard. But it should work. Basically we generate a struct type that's like struct vec
	-- (see vec.c/vec.h), but all the void *s, have been replaced by the actual types.
	-- This may not be the best approach but it reduces gc pressure a lot because we don't
	-- need to keep creating and throwing away temporary Lua tables.
	-- It also may speed up band accesses a bit, though this alone wouldn't be worth it.
	-- BIG NOTE: IF YOU CHANGE THE STRUCT IN VEC.H THEN THIS ALSO NEEDS TO CHANGE
	-- (TODO add unit test ensuring this doesn't happen)

	-- Layout must match struct vec_info! The generated struct looks like this:
	--  struct {
	--      unsigned ___nbands;
	--      unsigned band1, ..., bandN; // <- unsigned stride[]
	--  }
	local names = table.concat(typ.fields, ", ")
	local metact = ffi.typeof(string.format([[
		struct {
			unsigned ___nbands;
			unsigned %s;
		}
	]], names, names))

	local bandnames, bandtypes = {}, {}
	for idx,field in ipairs(typ.fields) do
		bandnames[idx] = string.format("$ *%s", field)
		bandtypes[idx] = typ.vars[field].ctype
	end

	-- Layout must match struct vec! The generated struct looks like this:
	--
	-- struct {
	--     struct vec_info *___info;
	--     unsigned ___nalloc;
	--     unsigned ___nused;
	--     type1 *band1;                // <- void *bands[]
	--     ...
	--     typeN *bandN;
	-- }
	local ct = ffi.typeof(string.format([[
		struct {
			$ *___info;
			unsigned ___nalloc;
			unsigned ___nused;
			%s;
		}
	]], table.concat(bandnames, "; ")), metact, unpack(bandtypes))

	-- Layout must match struct vec_slice! The generated struct here is just vec_slice but
	-- the struct_vec * pointer replaced with the generated ctype:
	--
	-- struct {
	--     struct <vectype> *vec;
	--     unsigned from;
	--     unsigned to;
	-- }
	local slicect = ffi.typeof([[
		struct {
			$ *vec;
			unsigned from;
			unsigned to;
		}
	]], ct)

	return metact, ffi.metatype(ct, vec_mt), ffi.metatype(slicect, slice_mt)
end

local function initmeta(sim, typ, metact)
	local metap = ffi.typeof("$*", metact)
	local meta = ffi.cast(metap, C.sim_alloc(sim, ffi.sizeof(metact), ffi.alignof(metact),
		C.SIM_STATIC))
	meta.___nbands = #typ.fields

	for _,name in ipairs(typ.fields) do
		meta[name] = ffi.sizeof(typ.vars[name].ctype)
	end

	return meta
end

local soa_mt = { __index={} }

local function new(sim, typ)
	local metact, vct, slicect = genvectypes(sim, typ)
	local meta = initmeta(sim, typ, metact)

	return setmetatable({
		sim      = sim,
		type     = typ,
		vec_ctp  = ffi.typeof("$*", vct),
		slice_ct = slicect,
		vec_info = meta
	}, soa_mt)
end

local info_ctp = ffi.typeof("struct vec_info *")
function soa_mt:__call()
	return ffi.cast(self.vec_ctp, C.simL_vec_create(
		self.sim,
		ffi.cast(info_ctp, self.vec_info),
		C.SIM_VSTACK)
	)
end

function soa_mt.__index:slice(vec, from, to)
	return self.slice_ct(vec, from or 0, to or #vec)
end

function soa_mt.__index:alloc(vec, n)
	local pos = vec:alloc(n)
	return self:slice(vec, pos, pos+n)
end

-------------------- fhk mapping --------------------

local function band_offsets(typ, band)
	return coroutine.wrap(function(soa)
		local f = typ.fields[band]
		if f.vars then
			typing.yield_offsets(field, 0)
		else
			coroutine.yield(f, 0, typ.vars[f])
		end
	end)
end

local function mapper(soa)
	local info = {}

	local typ = soa.type
	for band, name in ipairs(typ.fields) do
		local stride = ffi.sizeof(typ.vars[name].ctype)
		for field, offset, tp in band_offsets(typ, band) do
			info[field] = {
				band   = band-1,
				offset = offset,
				stride = stride,
				type   = tp
			}
		end
	end

	return function(name, how)
		local i = info[name]

		how = how or "follow"
		return i and function(solver, mapper, var)
			local arena = solver:arena()
			local udata = fhk.udata(solver)

			if udata[soa] and udata[soa].how ~= how then
				error(string.format("mapping conflict: can't map same structure as '%s' and '%s'",
					udata[soa].how, how))
			end

			if not udata[soa] then
				udata[soa] = {
					vp   = arena:new(vec_ctp),
					idxp = how == "static" and arena:new("unsigned"),
					how  = how
				}
			end

			local vv = arena:new("struct fhkM_vecV")
			vv.offset = i.offset
			vv.stride = i.stride
			vv.band = i.band
			vv.vec = udata[soa].vp
			vv.idx = udata[soa].idxp or udata.idxp
			return C.fhkM_pack_vecV(mapper:infer_desc(var, i.type), vv), how == "static"
		end
	end
end

function soa_mt.__index:fhk_map(...)
	if not self._mapper then
		self._mapper = mapper(self)
	end

	return self._mapper(...)
end

function soa_mt.__index:fhk_mapper(how)
	return function(name)
		return self:fhk_map(name, how)
	end
end

local function alloc_result(sim, solver, nv, n)
	local res_size = n * ffi.sizeof("pvalue")

	for i=0, nv-1 do
		local res = C.sim_alloc(sim, res_size, ffi.alignof("pvalue"), C.SIM_FRAME)
		solver:bind(i, res)
	end
end

local function bind_result(solver, nv, bufs)
	for i=0, nv-1 do
		-- bufs is a lua array, so +1
		solver:bind(i, ffi.cast("pvalue *", bufs[i+1]))
	end
end

function soa_mt.__index:fhk_over(solver)
	local arena = solver:arena()
	local iter = arena:new("struct fhkM_iter_range")
	C.fhkM_range_init(iter)
	local vp = arena:new(vec_ctp)

	local udata = fhk.udata(solver)
	udata.vp = vp
	udata.idxp = typing.memb_ptr("struct fhkM_iter_range", "idx", iter, "unsigned *")
	udata.how = "follow"
	udata[self] = udata

	local c_solver = solver:create(iter)
	local nv = #solver.names
	local sim = self.sim

	-- alloc:
	-- * nil          -> allocate buffers of size vec:alloc_len() on sim memory
	-- * number (n)   -> allocate buffers of size n on sim memory
	-- * table        -> solve to given buffers
	return function(vec, alloc)
		if not alloc then
			alloc_result(sim, c_solver, nv, vec.___nalloc)
		elseif type(alloc) == "number" then
			alloc_result(sim, c_solver, nv, alloc)
		else
			bind_result(c_solver, nv, alloc)
		end

		vp[0] = ffi.cast(vec_ctp, vec)
		iter.len = #vec
		return c_solver()
	end
end

function soa_mt.__index:fhk_bind(solver, vec, idx)
	local udata = fhk.udata(solver)[self]
	udata.vp[0] = ffi.cast(vec_ctp, vec)
	if idx then udata.idxp[0] = idx end
end

function soa_mt.__index:fhk_solver_ptr(solver)
	local udata = fhk.udata(solver)[self]
	local vp = ffi.cast(self.vec_ctp, udata.vp[0])
	local idx = tonumber(udata.idxp and udata.idxp[0] or fhk.udata(solver).idxp[0])
	return vp, idx
end

--------------------------------------------------------------------------------

local function soa_func(sim)
	local _sim = sim._sim
	return {
		new     = function(typ)
			return new(_sim, typing.totype(typ))
		end,

		newband = function(vec, name)
			local old = vec[name]
			vec[name] = C.simF_vec_create_band_stride(
				_sim,
				ffi.cast(vec_ctp, vec),
				vec.___info[name]
			)
			return vec[name], old
		end,

		alloc   = function(vec, n)
			return (tonumber(C.simF_vec_alloc(_sim, ffi.cast(vec_ctp, vec), n)))
		end
	}
end

--------------------------------------------------------------------------------

local function soa_loop(...)
	local bands = {...}
	local bandidx = {}
	for i,v in ipairs(bands) do
		bandidx[i] = string.format("___vec['%s'][___i]", v)
	end

	return {
		signature = "return function(___vec, ___state)",
		header    = "for ___i=0, #___vec-1 do",
		init      = string.format("%s, ___state", table.concat(bandidx, ", "))
	}
end

local function inject(env)
	env.m2.soa = soa_func(env.sim)
	env.m2.kernel.soa = function(...) return kernel.create(soa_loop(...)) end
end

return {
	inject = inject
}
