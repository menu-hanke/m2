local ffi = require "ffi"
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

local obj_mt = { __index={} }
local objvec_mt = { __index={} }

local function obj(sim, name, type)
	assert(type.fields)
	return setmetatable({
		sim        = sim,
		name       = name,
		type       = type,
		bands      = band_names_map(type),
		band_ctype = band_ctypes(type),
		tpl        = vec_template(type),
		id         = nextuniq()
	}, obj_mt)
end

function obj_mt.__index:spatial(zname)
	assert(not self.z_band)
	assert(self.type.vars[zname].ctype == "gridpos")
	self.z_band = self.bands[zname]
	return self
end

function obj_mt.__index:grid(order)
	assert(self.z_band)
	assert(not self.svgrid)
	self.svgrid = ffi.C.sim_create_svgrid(self.sim, order, self.z_band, self.tpl)
	return self
end

function obj_mt.__index:vec()
	return setmetatable({
		obj = self,
		vec = ffi.C.sim_create_vec(self.sim, self.tpl, ffi.C.SIM_FRAME + ffi.C.SIM_MUTABLE)
	}, objvec_mt)
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
	mapper:mark_visible(vmask, ffi.C.GMAP_BIND_OBJECT, typing.tvalue.u64(self.id))
	if self.z_band then
		mapper:mark_visible(vmask, ffi.C.GMAP_BIND_Z, typing.tvalue.u64(ffi.C.POSITION_ORDER))
	end
end

function obj_mt.__index:mark_nonconstant(mapper, vmask)
	mapper:mark_nonconstant(vmask, ffi.C.GMAP_BIND_OBJECT, typing.tvalue.u64(self.id))
	if self.svgrid then
		mapper:mark_nonconstant(vmask, ffi.C.GMAP_BIND_Z, typing.tvalue.u64(self.svgrid.grid.order))
	end
end

function obj_mt.__index:solver_func(mapper, solver)
	local v_bind = mapper.bind.vec[self.name]
	local svb = fhk.solver_vec_bind(v_bind.ref)
	if self.z_band then
		local z_bind = mapper.bind.z.global
		svb:bind_z(self.z_band, z_bind.ref)
	end

	local sim = self.sim
	return function(vec)
		fhk.rebind(sim, solver, vec:len())
		svb:solve_vec(solver, vec.vec)
	end
end

function objvec_mt.__index:len()
	return self.vec.n_used
end

function objvec_mt.__index:band(name)
	local band = self.obj.bands[name]
	local ctype = self.obj.band_ctype[band]
	return ffi.cast(ctype, self.vec.bands[band].data)
end

function objvec_mt.__index:newband(name)
	local band = self.obj.bands[name]
	local ctype = self.obj.band_ctype[band]
	return ffi.cast(ctype, ffi.C.frame_create_band(self.obj.sim, self.vec, band))
end

function objvec_mt.__index:swap(name, data)
	local band = self.obj.bands[name]
	ffi.C.frame_swap_band(self.obj.sim, self.vec, band, data)
end

function objvec_mt.__index:alloc(num)
	return tonumber(ffi.C.frame_alloc_vec(self.obj.sim, self.vec, num))
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
	mapper:mark_nonconstant(vmask. ffi.C.GMAP_BIND_GLOBAL, typing.tvalue.u64(0))
end

function globals_mt.__index:solver_func(mapper, solver)
	local values = ffi.cast("pvalue *", ffi.C.sim_static_alloc(self.sim,
		solver.nv * ffi.sizeof("pvalue"), ffi.alignof("pvalue")))
	
	for i=0, tonumber(solver.nv)-1 do
		solver:bind(i, values+i)
	end

	return function()
		ffi.C.fhk_solver_step(solver, 0)
	end
end

--------------------------------------------------------------------------------

local function get_ctype(name, ctype, env)
	if type(ctype) == "string" then return ctype end
	if ctype and ctype.ctype then return ctype.ctype end
	return env.fhk.typeof(name).ctype
end

local function inject(env, sim)
	env.obj = delegate(sim, obj)

	local gs = globals(sim)
	env.globals = gs
	env.G = gs.G

	gs.new = function(name, ctype) gs.define(name, get_ctype(name, ctype, env), false) end
	gs.static = function(name, ctype) gs.define(name, get_ctype(name, ctype, env), true) end
end

return {
	inject = inject
}
