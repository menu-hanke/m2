local ffi = require "ffi"
local vmath = require "vmath"
local fhk = require "fhk"
local typing = require "typing"

local function vec_template(type)
	-- luajit doesn't play nice with the empty array in struct so we have to malloc manually here
	local vec = ffi.cast("struct vec *", ffi.C.malloc(ffi.C.vec_header_size(#type.fields)))
	ffi.gc(vec, ffi.C.free)
	ffi.C.vec_init(vec, #type.fields)

	for band,field in ipairs(type.fields) do
		vec.bands[band-1].stride = ffi.sizeof(type.vars[field].ctype)
	end

	return vec
end

local function map_field(map, band, container, field, off)
	local t = container.vars[field]

	if t.vars then
		for _,name in ipairs(t.fields) do
			map_field(map, band, t, name, off+typing.offsetof(t, name))
		end
	else
		map(field, off, band-1)
	end
end

local function map_bands(type, map)
	for band,field in pairs(type.fields) do
		map_field(map, band, type, field, 0)
	end
end

local function contains_field(container, field)
	if container.vars[field] then
		return true
	end

	for name,t in pairs(container.vars) do
		if t.vars and contains_field(t, field) then
			return true
		end
	end
end

local function find_container_band(type, name)
	for band,field in ipairs(type.fields) do
		if field == name then
			return band
		end

		local t = type.vars[field]
		if t.vars and contains_field(t, name) then
			return band
		end
	end
end

local function band_names_map(type)
	local ret = {}

	for band,field in ipairs(type.fields) do
		ret[field] = band-1
	end

	return ret
end

local function band_ctypes(type)
	local ret = {}

	for band,field in ipairs(type.fields) do
		ret[band-1] = type.vars[field].ctype .. "*"
	end

	return ret
end

--------------------------------------------------------------------------------

local rvec_mt = {
	__index = function(self, idx) return self.wrap(self.data[idx]) end,
	__newindex = function(self, idx, v) self.data[idx] = self.unwrap(v) end
}

local function refvec(wrap, unwrap)
	return function(data)
		return setmetatable({wrap=wrap, unwrap=unwrap, data=data}, rvec_mt)
	end
end

--------------------------------------------------------------------------------

local obj_callbacks = callbacks {
	mark_visible = function(self, mapper, vmask)
		mapper:mark_visible(vmask, ffi.C.GMAP_BIND_OBJECT, typing.tvalue.u64(self.id))
	end,

	mark_nonconstant = function(self, mapper, vmask)
		mapper:mark_nonconstant(vmask, ffi.C.GMAP_BIND_OBJECT, typing.tvalue.u64(self.id))
	end
}

local zobj_callbacks = callbacks {
	mark_visible = function(self, mapper, vmask)
		mapper:mark_visible(vmask, ffi.C.GMAP_BIND_Z, typing.tvalue.u64(ffi.C.POSITION_ORDER))
	end
}

local svobj_callbacks = callbacks {
	mark_nonconstant = function(self, mapper, vmask)
		mapper:mark_nonconstant(vmask, ffi.C.GMAP_BIND_Z, typing.tvalue.u64(self.svgrid.grid.order))
	end
}

local objvec_callbacks = callbacks {
	bind = function(self, mapper, idx)
		local vbind = mapper.bind.vec[self.obj.name]
		vbind.ref.vec = self.vec
		vbind.ref.idx = idx
	end
}

local zobjvec_callbacks = callbacks {
	bind = function(self, mapper, idx)
		local zb = ffi.cast("gridpos *", self.vec.bands[self.obj.z_band].data)
		mapper.bind.z.global(zb[idx])
	end
}

local function objvec_solver(self, mapper, solver)
	local v_bind = mapper.bind.vec[self.name].ref
	local sim = self.sim

	return function(vec)
		-- TODO: allow configuring if this should allocate vec:len() or vec.n_alloc
		fhk.rebind(sim, solver, vec.vec.n_alloc)
		return (ffi.C.gs_solve_vec(v_bind, solver, vec.vec))
	end
end

local function objvec_solver_z(self, mapper, solver)
	local v_bind = mapper.bind.vec[self.name].ref
	local z_bind = mapper.bind.z.global.ref
	local z_band = self.z_band
	local sim = self.sim

	return function(vec)
		-- TODO: see objvec_solver
		fhk.rebind(sim, solver, vec.vec.n_alloc)
		return (ffi.C.gs_solve_vec_z(v_bind, z_bind, z_band, solver, vec.vec))
	end
end

local obj_mt = { __index={} }
local objvec_mt = { __index={} }

local function obj(sim, name, type)
	assert(type.fields)
	return setmetatable({
		sim         = sim,
		name        = name,
		type        = type,
		bands       = band_names_map(type),
		band_ctype  = band_ctypes(type),
		typehints   = {},
		tpl         = vec_template(type),
		callbacks   = obj_callbacks,
		vcallbacks  = objvec_callbacks,
		solver_func = objvec_solver,
		id          = nextuniq()
	}, obj_mt)
end

function obj_mt.__index:spatial(zname)
	assert(not self.z_band)
	assert(self.type.vars[zname].ctype == "gridpos")
	self.z_band = self.bands[zname]
	self.callbacks = self.callbacks + zobj_callbacks
	self.vcallbacks = self.vcallbacks + zobjvec_callbacks
	self.solver_func = objvec_solver_z
	return self
end

function obj_mt.__index:grid(order)
	assert(self.z_band)
	assert(not self.svgrid)
	self.svgrid = ffi.C.sim_create_svgrid(self.sim, order, self.z_band, self.tpl)
	self.callbacks = self.callbacks + svobj_callbacks
	-- TODO: self.solver_func = obj_solver_grid
	return self
end

function obj_mt.__index:vec(ref)
	return setmetatable({
		obj = self,
		vec = ref or ffi.C.sim_create_vec(self.sim, self.tpl, ffi.C.SIM_FRAME + ffi.C.SIM_MUTABLE)
	}, objvec_mt)
end

function obj_mt.__index:typeof(name)
	return self.type.vars[name]
end

function obj_mt.__index:hint(name, ref)
	self.typehints[name] = ref
end

function obj_mt.__index:refvec()
	return refvec(
		function(ptr)
			return self:vec(ffi.cast("struct vec *", ptr))
		end,

		function(vec)
			return vec.vec
		end
	)
end

function obj_mt.__index:expose(mapper)
	local bind = mapper.bind.vec[self.name]
	map_bands(self.type, function(name, offset, band)
		if mapper.vars[name] then
			fhk.support.var(mapper:vec(name, offset, band, bind.ref), self.id)
		end
	end)
end

function obj_mt.__index:mark_visible(mapper, vmask)
	self.callbacks.mark_visible(self, mapper, vmask)
end

function obj_mt.__index:mark_nonconstant(mapper, vmask)
	self.callbacks.mark_nonconstant(self, mapper, vmask)
end

function obj_mt.__index:virtualize(mapper, name, f)
	local v_bind = mapper.bind.vec[self.name].ref

	fhk.support.var(mapper:virtual(name, function()
		return f(v_bind.idx, v_bind.vec)
	end), self.id)
end

----------------------------------------

function objvec_mt.__index:len()
	return self.vec.n_used
end

function objvec_mt.__index:typedvec(name, data)
	if self.obj.typehints[name] then
		return self.obj.typehints[name](data)
	else
		local type = self.obj:typeof(name)
		return vmath.typed(type, data, self:len())
	end
end

function objvec_mt.__index:band(name)
	local band = self.obj.bands[name]
	local ctype = self.obj.band_ctype[band]
	local data = self.vec.bands[band].data
	-- Note: use parenthesis here to prevent tailcall to builtin ffi.cast (this aborts the trace)
	return (ffi.cast(ctype, data))
end

function objvec_mt.__index:bandv(name)
	return self:typedvec(name, self:band(name))
end

function objvec_mt.__index:newband(name)
	local band = self.obj.bands[name]
	local ctype = self.obj.band_ctype[band]
	local data = ffi.C.frame_create_band(self.obj.sim, self.vec, band)
	-- see comment in band()
	return (ffi.cast(ctype, data))
end

function objvec_mt.__index:newbandv(name)
	return self:typedvec(name, self:newband(name))
end

function objvec_mt.__index:swap(name, data)
	local band = self.obj.bands[name]
	ffi.C.frame_swap_band(self.obj.sim, self.vec, band, vmath.todata(data))
end

function objvec_mt.__index:alloc(num)
	return tonumber(ffi.C.frame_alloc_vec(self.obj.sim, self.vec, num))
end

function objvec_mt.__index:bind(mapper, idx)
	self.obj.vcallbacks.bind(self, mapper, idx)
end

--------------------------------------------------------------------------------

local globals_mt = { __index={} }

local function globalns(sim)
	local ns = {}

	local define = function(name, ctype, static)
		local lifetime = (static and 0) or (ffi.C.SIM_MUTABLE + ffi.C.SIM_FRAME)
		local d = ffi.C.sim_create_data(sim, ffi.sizeof(ctype), ffi.alignof(ctype), lifetime)
		ns[name] = ffi.cast(ctype .. "*", d)
	end

	return setmetatable({}, {
		__index = function(_, name)
			return ns[name][0]
		end,

		__newindex = function(_, name, value)
			ns[name][0] = value
		end
	}), define, ns
end

local function globals(sim)
	local G, define, ns = globalns(sim)
	return setmetatable({
		sim = sim,
		G = G,
		define = define,
		ns = ns
	}, globals_mt)
end

function globals_mt.__index:expose(mapper)
	for name,p in pairs(self.ns) do
		if mapper.vars[name] then
			fhk.support.global(mapper:data(name, p))
		end
	end
end

function globals_mt.__index:mark_visible(mapper, vmask)
	mapper:mark_visible(vmask, ffi.C.GMAP_BIND_GLOBAL, typing.tvalue.u64(0))
end

function globals_mt.__index:mark_nonconstant(mapper, vmask)
	mapper:mark_nonconstant(vmask, ffi.C.GMAP_BIND_GLOBAL, typing.tvalue.u64(0))
end

function globals_mt.__index:solver_func(mapper, solver)
	local values = ffi.cast("pvalue *", ffi.C.sim_static_alloc(self.sim,
		solver.nv * ffi.sizeof("pvalue"), ffi.alignof("pvalue")))
	
	for i=0, tonumber(solver.nv)-1 do
		solver:bind(i, values+i)
	end

	return function()
		return (ffi.C.gs_solve_step(solver, 0))
	end
end

function globals_mt.__index:virtualize(mapper, name, f)
	fhk.support.global(mapper:virtual(name, f))
end

--------------------------------------------------------------------------------

local function get_ctype(name, ctype, env)
	if type(ctype) == "string" then return ctype end
	if ctype and ctype.ctype then return ctype.ctype end
	return env.fhk.typeof(name).ctype
end

local function globalsfunc(env, static)
	return function(names, ctype)
		names = type(names) == "string" and {names} or names
		ctype = type(ctype) == "string" and ctype or (ctype and ctype.ctype)
		for _,name in ipairs(names) do
			env.globals.define(name, ctype or env.fhk.typeof(name).ctype, static)
		end
	end
end

local function inject(env, sim)
	env.obj = delegate(sim, obj)

	local gs = globals(sim)
	gs.dynamic = globalsfunc(env, false)
	gs.static = globalsfunc(env, true)

	env.globals = gs
	env.G = gs.G
end

return {
	inject = inject
}
