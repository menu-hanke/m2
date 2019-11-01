local ffi = require "ffi"
local typing = require "typing"
local vmath = require "vmath"
local code = require "code"
local fhk = require "fhk"
local C = ffi.C

--------------------------------------------------------------------------------

local vec_mt = { __index = {} }

function vec_mt.__index:len()
	return self.vec.___nused
end

function vec_mt.__index:alloc_len()
	return self.vec.___nalloc
end

function vec_mt.__index:cvec()
	return ffi.cast("struct vec *", self.vec)
end

function vec_mt.__index:cinfo()
	return ffi.cast("struct vec_info *", self.vec.___info)
end

function vec_mt.__index:info()
	return self.vec.___info
end

function vec_mt.__index:typedvec(name, data)
	return vmath.typed(tonumber(self:info().desc[name]), data, self:len())
end

function vec_mt.__index:band(name)
	return self.vec[name]
end

function vec_mt.__index:bandv(name)
	return self:typedvec(name, self:band(name))
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

local vcomp_bind = ffi.typeof [[
	struct {
		unsigned offset;
		unsigned *idx;
		struct vec *vec;
	}
]]

local function structp(t, s, x)
	-- This is a bit ugly but luajit doesn't let me directly take the address of a struct member
	-- so I have to use a workaround.
	-- This will return (void *) &s.x, where s is a struct and x is a field
	return ffi.cast("void *", ffi.cast("char *", s) + ffi.offsetof(t, x))
end

local component_mt = { __index={} }

local function component(type, base)
	base = base or {}
	base.events = base.events or {}
	base._lazy = {}
	base.type = type
	return setmetatable(base, component_mt)
end

function component_mt.__index:bind(mapper, obj, offset, vec, idxp)
	if not self.id then
		return
	end

	self.vc_bind.offset = offset
	self.vc_bind.vec = vec
	self.vc_bind.idx = idxp

	-- store the currently bound object because we may need to cast the vector later in virtual
	self.obj = obj
end

function component_mt.__index:is_mapped()
	return self.id ~= nil
end

function component_mt.__index:any_mapped(mapper)
	for _,field in ipairs(self.type.fields) do
		if mapper.vars[field] then
			return true
		end
	end
end

local function map_field(map, band, stride, container, field, off)
	local t = container.vars[field]

	if t.vars then
		for _,name in ipairs(t.fields) do
			map_field(map, band, stride, t, name, off+typing.offsetof(t, name))
		end
	else
		map(field, off, stride, band-1)
	end
end

function component_mt.__index:map_bands(map)
	for band,field in ipairs(self.type.fields) do
		map_field(map, band, ffi.sizeof(self.type.vars[field].ctype), self.type, field, 0)
	end
end

function component_mt.__index:lazy_compute_band(band, vs, field)
	return self._lazy[field](band, vs)
end

function component_mt.__index:lazy(field, f)
	self._lazy[field] = f
end

function component_mt.__index:is_lazy(field)
	return self._lazy[field] ~= nil
end

-------------------- mapper --------------------

function component_mt.__index:expose(mapper)
	if self:is_mapped() or not self:any_mapped(mapper) then
		return
	end

	self.id = mapper:new_objid()

	-- the address needs to stay constant (gv_vcomponent will point here) so ffi can't be used here
	self.vc_bind = mapper.arena:new(vcomp_bind)

	local op = structp(vcomp_bind, self.vc_bind, "offset")  -- &bind.offset
	local ip = structp(vcomp_bind, self.vc_bind, "idx")     -- &bind.idx
	local vp = structp(vcomp_bind, self.vc_bind, "vec")     -- &bind.vec

	self:map_bands(function(name, offset, stride, band)
		if mapper.vars[name] then
			local v = mapper:vcomponent(name, offset, stride, band, op, ip, vp)
			fhk.support.var(v, self.id)
		end
	end)

	-- this only makes sense for primitives
	for band,name in ipairs(self.type.fields) do
		if self:is_lazy(name) and mapper.vars[name] then
			local f = self._lazy[name]
			mapper:lazy(name, function()
				local v = ffi.cast(self.obj.vec_ctp, self.vc_bind.vec)
				f(v:newband(name), v)
			end)
		end
	end
end

function component_mt.__index:virtualize(mapper, name, f)
	fhk.support.var(mapper:virtual(name, function()
		return f(ffi.cast(self.obj.vec_ctp, self.vc_bind.vec), tonumber(self.vc_bind.idx[0]))
	end), self.id)
end

--------------------------------------------------------------------------------

local function zcomponent(name, typename)
	local type = typing.newtype(typename or string.format("%s_z", name))
	type.vars[name] = typing.builtin_types.z

	local comp = component(type)

	comp.bind = function(comp, mapper, offset, vec, idx)
		if comp.id and vec then
			mapper.bind.z.global(vec:band(name)[idx])
		end
	end

	comp.solver_func = function(obj, mapper, solver)
		local z_bind = mapper.bind.z.global.ref
		local z_band = obj.offsets[comp]

		return function(vec)
			obj:bind(mapper, vec)
			fhk.rebind(obj.sim, solver, vec:alloc_len())
			return (C.gs_solve_vec_z(vec:cvec(), solver, z_bind, z_band, self.solver_idxp))
		end
	end

	comp.events.mark_visible = function(obj, mapper, vmask)
		mapper:mark_visible(vmask, C.GMAP_BIND_Z, typing.tvalue.u64(C.POSITION_ORDER))
	end

	return comp
end

--------------------------------------------------------------------------------

local function collect_bands(comps)
	local bands = {}
	local offsets = {}
	local containers = {}

	local band = 0
	for _,c in ipairs(comps) do
		local t = c.type
		offsets[c] = band

		for _,field in ipairs(t.fields) do
			if containers[field] then
				error("Name clash: %s", field)
			end

			containers[field] = c

			-- lua table, so it's 1 indexed
			bands[band+1] = {
				name = field,
				type = t.vars[field]
			}

			band = band + 1
		end
	end

	return bands, offsets, containers
end

local function genvectypes(sim, bands)
	-- Note: this might not be completely safe and it's definitely not defined behavior by C
	-- standard. But it should work. Basically we generate a struct type that's like struct vec
	-- (see vec.c/vec.h), but all the void *s, have been replaced by the actual types.
	-- This may not be the best approach but it reduces gc pressure a lot because we don't
	-- need to keep creating and throwing away temporary Lua tables.
	-- It also may speed up band accesses a bit, though this alone wouldn't be worth it.
	-- BIG NOTE: IF YOU CHANGE THE STRUCT IN VEC.H THEN THIS ALSO NEEDS TO CHANGE
	-- (TODO add unit test ensuring this doesn't happen)
	
	local bs = {}
	local bnames = {}

	for _,b in ipairs(bands) do
		table.insert(bs, string.format("%s *%s", b.type.ctype, b.name))
		table.insert(bnames, b.name)
	end

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
	bnames = table.concat(bnames, ", ")
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
	]], table.concat(bs, "; ")), metact)

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

local function initmeta(sim, bands, metact)
	local metap = ffi.typeof("$*", metact)
	local meta = ffi.cast(metap, C.sim_static_alloc(sim, ffi.sizeof(metact), ffi.alignof(metact)))
	meta.stride.___nbands = #bands
	meta.sim = sim

	for _,b in ipairs(bands) do
		meta.desc[b.name] = b.type.desc or typing.udata.desc
		meta.stride[b.name] = ffi.sizeof(b.type.ctype)
	end

	return meta
end

local function collect_lazy(bands, bcomp)
	local idx = {}
	for i, b in ipairs(bands) do
		if bcomp[b.name]._lazy[b.name] then
			table.insert(idx, i-1)
		end
	end

	return {n=#idx, buf=ffi.new("unsigned[?]", #idx, idx)}
end

local obj_mt = { __index={} }

local function obj(sim, comps)
	local bands, offsets, band_comps = collect_bands(comps)
	local metact, vct, slicect = genvectypes(sim, bands)
	local meta = initmeta(sim, bands, metact)

	local ret = setmetatable({
		sim        = sim,
		vec_ctp    = ffi.typeof("$*", vct),
		slice_ct   = slicect,
		vec_info   = ffi.cast("struct vec_info *", meta),
		comps      = comps,        -- component list
		band_comps = band_comps,   -- band name -> component mapping
		offsets    = offsets,      -- component -> offset (index) mapping
		lazy_bands = collect_lazy(bands, band_comps) -- {n=num, buf=lazy band indices}
	}, obj_mt)

	ret:specialize()

	return ret
end

function obj_mt.__index:vec()
	return (ffi.cast(self.vec_ctp, C.simL_vec_create(self.sim, self.vec_info, C.SIM_VSTACK)))
end

function obj_mt.__index:slice(vec, from, to)
	return self.slice_ct(vec, from or 0, to or vec:len())
end

function obj_mt.__index:alloc(vec, n)
	self:unrealize(vec)
	local pos = vec:alloc(n)
	return self:slice(vec, pos, pos+n)
end

function obj_mt.__index:realize(vs, field)
	local band = vs:band(field)
	if band == ffi.NULL then
		band = vs:newband(field)
		self.band_comps[field]:lazy_compute_band(band, vs, field)
	end
	return band
end

function obj_mt.__index:realizev(vs, field)
	return vs:typedvec(field, self:realize(vs, field))
end

function obj_mt.__index:refresh(vs, field)
	local band = vs:band(field)
	if band ~= ffi.NULL then
		self.band_comps[field]:lazy_compute_band(band, vs, field)
	end
end

function obj_mt.__index:unrealize(vec)
	C.vec_clear_bands(vec:cvec(), self.lazy_bands.n, self.lazy_bands.buf)
end

local function wrap(event, f)
	if not event then
		return f
	end

	-- TODO: may need to generate code or use string.dump+load here if this has bad performance
	return function(...)
		event(...)
		f(...)
	end
end

function obj_mt.__index:specialize()
	for _,c in ipairs(self.comps) do
		for event,f in pairs(c.events) do
			self[event] = wrap(self[event], f)
		end
	end

	-- only 1 component may override the solver, otherwise we will just do multiple runs over
	-- the vector with different data available
	local sf
	for _,c in ipairs(self.comps) do
		if c.solver_func then
			if solver_func then
				error(string.format("Only 1 component may override solver"))
			end
			sf = c.solver_func
		end
	end

	if sf then
		self.solver_func = sf
	end

	self:specialize_realization()
end

function obj_mt.__index:specialize_bind()
	-- "unroll" these to prevent a huge amount of small 1-3 element loops
	-- codegen is not a very elegant solution here, but since bind is often called in a
	-- loop over each element of some vector, we need performance here
	-- Note: don't call this function before calling expose()
	
	-- this creates the following function:
	--
	-- local c1 = self.comps[1]
	-- local off1 = self.offsets[c1]
	-- ...
	-- local cN = self.comps[N]
	-- local offN = self.offsets[N]
	--
	-- self._bind = function(self, mapper, vec, idxp)
	--     c1:bind(mapper, self, off1, vec, idxp)
	--     ...
	--     cN:bind(mapper, self, offN, vec, idxp)
	-- end

	local binds = {}

	for _,c in ipairs(self.comps) do
		if c:is_mapped() then
			table.insert(binds, {off=self.offsets[c], c=c})
		end
	end

	local bind = code.new()

	for i,b in ipairs(binds) do
		bind:emitf("local c%d = binds[%d].c; local off%d = binds[%d].off;", i, i, i, i)
	end

	bind:emit("return function(self, mapper, vec, idxp)")
	
	for i,b in ipairs(binds) do
		bind:emitf("c%d:bind(mapper, self, off%d, vec, idxp)", i, i)
	end

	bind:emit("end")
	self._bind = bind:compile({binds=binds}, "=(bind)")()
end

function obj_mt.__index:specialize_realization()
	-- same idea as the above function, if the realizations are called in a loop, we get a side
	-- trace for each one, which is absolutely not what we want
	
	-- this creates the following function:
	--
	-- local NULL  = ffi.NULL
	-- local lazy1 = lazy[1].band
	-- local comp1 = lazy[1].comp
	-- ...
	-- local lazyN = lazy[N].band
	-- local compN = lazy[N].comp
	--
	-- self.refresh_slice = function(self, slice)
	--     local band
	--     band = slice:band(lazy1)
	--     if band ~= ffi.NULL then comp1:lazy_compute_band(band, slice, lazy1) end
	--     ...
	--     band = slice:band(lazyN)
	--     if band ~= ffi.NULL then compN:lazy_compute_band(band, slice, lazyN) end
	-- end
	
	local lazy = {}
	for band, comp in pairs(self.band_comps) do
		if comp:is_lazy(band) then
			table.insert(lazy, {band=band, comp=comp})
		end
	end

	local rlz = code.new()

	rlz:emit("local NULL = NULL")

	for i,l in ipairs(lazy) do
		rlz:emitf("local lazy%d = lazy[%d].band; local comp%d = lazy[%d].comp", i, i, i, i)
	end

	rlz:emit("return function(self, slice)")
	rlz:emit("local band")

	for i,l in ipairs(lazy) do
		rlz:emitf("band = slice:band(lazy%d)", i)
		rlz:emitf("if band ~= NULL then comp%d:lazy_compute_band(band, slice, lazy%d) end", i, i)
	end

	rlz:emit("end")
	self.refresh_slice = rlz:compile({lazy=lazy, NULL=NULL}, "=(refresh_slice)")()
end

-------------------- mapper callbacks --------------------

function obj_mt.__index:bind(mapper, vec, idx)
	self:_bind(mapper, vec:cvec(), self.solver_idxp)

	if idx then
		self.solver_idxp[0] = idx
	end
end

function obj_mt.__index:expose(mapper)
	local id = 0ULL

	for _,c in ipairs(self.comps) do
		c:expose(mapper)
		if c.id then
			id = bit.bor(id, c.id)
		end
	end

	self.id = id
	self.solver_idxp = mapper.arena:new("unsigned")
	self:specialize_bind()
end

function obj_mt.__index:solver_func(mapper, solver)
	return function(vec)
		-- TODO: this should also accept slice?

		-- No need to explicitly bind idx here, gs_solve_vec binds it while stepping
		self:bind(mapper, vec)

		-- TODO: allow configuring if this should allocate vec:len() or vec.n_alloc
		fhk.rebind(self.sim, solver, vec:alloc_len())
		return (C.gs_solve_vec(vec:cvec(), solver, self.solver_idxp))
	end
end

function obj_mt.__index:mark_visible(mapper, G, vmask)
	G:mark_visible(vmask, C.GMAP_BIND_OBJECT, typing.tvalue.u64(self.id))
end

function obj_mt.__index:mark_nonconstant(mapper, G, vmask)
	G:mark_nonconstant(vmask, C.GMAP_BIND_OBJECT, typing.tvalue.u64(self.id))
end

--------------------------------------------------------------------------------

local function inject(env, sim)
	env.component = component
	env.obj = function(...) return obj(sim, {...}) end
end

return {
	inject = inject
}
