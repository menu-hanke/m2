local ffi = require "ffi"
local aux = require "aux"
local typing = require "typing"
local vmath = require "vmath"
local kernel = require "kernel"
local fhk = require "fhk"
local C = ffi.C

--------------------------------------------------------------------------------

local vec_mt = { __index = {} }

function vec_mt.__index:len()
	return self.vec.___nused
end

vec_mt.__len = vec_mt.__index.len

function vec_mt.__index:alloc_len()
	return self.vec.___nalloc
end

function vec_mt.__index:cvec()
	return (ffi.cast("struct vec *", self.vec))
end

function vec_mt.__index:cinfo()
	return (ffi.cast("struct vec_info *", self.vec.___info))
end

function vec_mt.__index:info()
	return self.vec.___info
end

local typed = vmath.typed
function vec_mt.__index:typedvec(name, data)
	return (typed(tonumber(self:info().desc[name]), data, self:len()))
end

function vec_mt.__index:band(name)
	return self.vec[name]
end

function vec_mt.__index:bandv(name)
	return (self:typedvec(name, self:band(name)))
end

function vec_mt.__index:newband(name)
	local old = self.vec[name]
	self.vec[name] = C.simF_vec_create_band_stride(self:info().sim, self:cvec(),
		self:info().stride[name])
	return self.vec[name], old
end

function vec_mt.__index:newbandv(name)
	local new, old = self:newband(name)
	return self:typedvec(name, new), self:typedvec(name, old)
end

function vec_mt.__index:swap(name, data)
	local old = self.vec[name]
	self.vec[name] = data
	return old
end

function vec_mt.__index:clear(name)
	return self:swap(name, ffi.NULL)
end

function vec_mt.__index:alloc(n)
	return (tonumber(C.simF_vec_alloc(self:info().sim, self:cvec(), n)))
end

local slice_mt = { __index = {} }

function slice_mt.__index:len()
	return self.to - self.from
end

slice_mt.__len = slice_mt.__index.len

function slice_mt.__index:typedvec(name, data)
	return vmath.typed(tonumber(self.vec:info().desc[name]), data, self:len())
end

function slice_mt.__index:band(name)
	local band = self.vec:band(name)
	if band ~= ffi.NULL then
		band = band + self.from
	end
	return band
end

function slice_mt.__index:bandv(name)
	return self:typedvec(name, self:band(name))
end

--------------------------------------------------------------------------------

local function genvectypes(sim, typ)
	-- Note: this might not be completely safe and it's definitely not defined behavior by C
	-- standard. But it should work. Basically we generate a struct type that's like struct vec
	-- (see vec.c/vec.h), but all the void *s, have been replaced by the actual types.
	-- This may not be the best approach but it reduces gc pressure a lot because we don't
	-- need to keep creating and throwing away temporary Lua tables.
	-- It also may speed up band accesses a bit, though this alone wouldn't be worth it.
	-- BIG NOTE: IF YOU CHANGE THE STRUCT IN VEC.H THEN THIS ALSO NEEDS TO CHANGE
	-- (TODO add unit test ensuring this doesn't happen)

	-- Layout (beginning) must match struct vec_info! The generated struct looks like this:
	--
	-- struct {                            // <- vec->info points here
	--     struct {                        // <- so stride info must be first member!
	--         unsigned ___nbands;
	--         unsigned band1, ..., bandN; // <- unsigned stride[]
	--     } stride;
	--     // ------ vec_info ends ------
	--     struct {
	--         uint8_t band1, ..., bandN;  // <- type info
	--     } desc;
	--     sim *sim;
	-- }
	local bnames = table.concat(typ.fields, ", ")
	local metact = ffi.typeof(string.format([[
		struct {
			struct {
				unsigned ___nbands;
				unsigned %s;
			} stride;
			struct {
				uint8_t %s;
			} desc;
			sim *sim;
		}
	]], bnames, bnames))
	
	local bandp = {}

	for idx,field in ipairs(typ.fields) do
		bandp[idx] = string.format("%s *%s", typ.vars[field].ctype, field)
	end

	-- Layout must match struct vec! The generated struct looks like this:
	--
	-- struct {
	--     struct <metadata> *___info;  // <- struct vec_info *
	--     unsigned ___nalloc;
	--     unsigned ___nused;
	--     type1 *band1;                // <- void *bands[]
	--     ...
	--     typeN *bandN;
	-- }
	--
	-- The vec is inside another struct so we can attach metatype functions to it without
	-- name clashing issues. this doesn't cause problems with the C api because a struct can
	-- always be cast to its first member.
	local ct = ffi.typeof(string.format([[
		struct {
			struct {
				$ *___info;
				unsigned ___nalloc;
				unsigned ___nused;
				%s;
			} vec;
		}
	]], table.concat(bandp, "; ")), metact)

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
	local meta = ffi.cast(metap, C.sim_static_alloc(sim, ffi.sizeof(metact), ffi.alignof(metact)))
	meta.stride.___nbands = #typ.fields
	meta.sim = sim

	for _,name in ipairs(typ.fields) do
		local t = typ.vars[name]
		meta.desc[name] = t.desc or typing.udata.desc
		meta.stride[name] = ffi.sizeof(t.ctype)
	end

	return meta
end

local obj_mt = { __index={} }

local function obj(sim, typ)
	local metact, vct, slicect = genvectypes(sim, typ)
	local meta = initmeta(sim, typ, metact)

	return setmetatable({
		sim        = sim,
		type       = typ,
		vec_ctp    = ffi.typeof("$*", vct),
		slice_ct   = slicect,
		vec_info   = ffi.cast("struct vec_info *", meta),
	}, obj_mt)
end

function obj_mt.__index:vec()
	return (ffi.cast(self.vec_ctp, C.simL_vec_create(self.sim, self.vec_info, C.SIM_VSTACK)))
end

function obj_mt.__index:slice(vec, from, to)
	return self.slice_ct(vec, from or 0, to or vec:len())
end

function obj_mt.__index:alloc(vec, n)
	local pos = vec:alloc(n)
	return self:slice(vec, pos, pos+n)
end

local function iter_field(offsets, band, stride, container, field, off)
	local t = container.vars[field]

	if t.vars then
		for _,name in ipairs(t.fields) do
			iter_field(offsets, band, stride, t, name, off+typing.offsetof(t, name))
		end
	else
		coroutine.yield(field, off, stride, band-1)
	end
end

function obj_mt.__index:field_info()
	return coroutine.wrap(function()
		for band,field in ipairs(self.type.fields) do
			iter_field(offsets, band, ffi.sizeof(self.type.vars[field].ctype), self.type, field, 0)
		end
	end)
end

-------------------- fhk mapping --------------------

function obj_mt.__index:define_mappings(solver, define)
	local udata = solver.udata[self]

	udata.vp = solver.arena:new("struct vec *")

	if udata.bind then
		udata.vp[0] = udata.bind:cvec()
	end

	if self ~= solver.source and not udata.follow then
		udata.idxp = solver.arena:new("unsigned")
	end

	for field, offset, stride, band in self:field_info() do
		define(field, function()
			local mapping = solver.arena:new("struct fhkM_vecV")
			mapping.flags.resolve = C.FHKM_MAP_VEC
			mapping.flags.offset = offset
			mapping.flags.stride = stride
			mapping.flags.band = band
			mapping.vec = udata.vp
			mapping.idx = udata.idxp or solver.udata.idxp
			return mapping, mapping.idx ~= solver.udata.idxp
		end)
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

function obj_mt.__index:wrap_solver(solver)
	local vp = solver.udata[self].vp
	local iter = solver.arena:new("struct fhkM_iter_range")
	C.fhkM_range_init(iter)
	solver.udata.idxp = typing.memb_ptr("struct fhkM_iter_range", "idx", iter, "unsigned *")

	local solve = solver:create_iter(iter)
	local c_solver = solver.solver
	local nv = solver.nv
	local sim = self.sim

	-- alloc:
	-- * nil          -> allocate buffers of size vec:alloc_len() on sim memory
	-- * number (n)   -> allocate buffers of size n on sim memory
	-- * table        -> solve to given buffers
	return function(vec, alloc)
		if not alloc then
			alloc_result(sim, c_solver, nv, vec:alloc_len())
		elseif type(alloc) == "number" then
			alloc_result(sim, c_solver, nv, alloc)
		else
			bind_result(c_solver, nv, alloc)
		end

		vp[0] = vec:cvec()
		iter.len = vec:len()
		return solve()
	end
end

function obj_mt.__index:bind_solver(solver, vec, idx)
	local udata = solver.udata[self]
	udata.vp[0] = vec:cvec()
	if idx then
		udata.idxp[0] = idx
	end
end

function obj_mt.__index:solver_pos(solver)
	local udata = solver.udata[self]
	local vp = ffi.cast(self.vec_ctp, udata.vp[0])
	local idx = tonumber(udata.idxp and udata.idxp[0] or solver.udata.idxp[0])
	return vp, idx
end

-- TODO: zband solver

--------------------------------------------------------------------------------

local function obj_loop(...)
	local bands = {...}
	local bandidx = {}
	for i,v in ipairs(bands) do
		bandidx[i] = string.format("___vec:band('%s')[___i]", v)
	end

	return {
		signature = "return function(___vec, ___state)",
		header    = "for ___i=0, ___vec:len()-1 do",
		init      = string.format("%s, ___state", table.concat(bandidx, ", "))
	}
end

local function inject(env)
	env.m2.obj = aux.delegate(env.sim._sim, obj)
	env.m2.kernel.bands = function(...) return kernel.create(obj_loop(...)) end
end

return {
	inject = inject
}
