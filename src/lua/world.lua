local ffi = require "ffi"
local vmath = require "vmath"
local typing = require "typing"
local C = ffi.C

ffi.cdef [[
	void *malloc(size_t size);
	void free(void *ptr);
]]

-------------------------

local function vecn(v)
	return tonumber(v.nuse)
end

local function vece(v, i)
	return v.data+i
end

-------------------------

local objvec = {}

function objvec:pvec(varid)
	local ret = ffi.new("struct pvec")
	C.w_obj_pvec(ret, self, varid)
	return vmath.vec(ret)
end

ffi.metatype("w_objvec", {__index=objvec})

-------------------------

local env = {}

function env:pvec()
	local pvec = ffi.new("struct pvec")
	C.w_env_pvec(pvec, self)
	return vmath.vec(pvec)
end

ffi.metatype("w_env", {__index=env})

-------------------------

local function tplidx(varid)
	return varid - C.BUILTIN_VARS_END
end

local function envtable(mes)
	return setmetatable({}, {__index=function(_, name)
		error(string.format(mes, name))
	end})
end

local function create_env_lex(_world, lex)
	local obj = envtable("No obj matching name '%s'")
	local var = envtable("No var matching name '%s'")
	local env = envtable("No env matching name '%s'")

	for i=0, vecn(lex.objs)-1 do
		local o = vece(lex.objs, i)
		obj[ffi.string(o.name)] = C.w_get_obj(_world, i)

		for j=0, vecn(o.vars)-1 do
			local v = vece(o.vars, j)
			var[ffi.string(v.name)] = v.id
		end
	end

	for i=0, vecn(lex.envs)-1 do
		local e = vece(lex.envs, i)
		env[ffi.string(e.name)] = C.w_get_env(_world, i)
	end

	return obj, var, env
end

-------------------------

local world = {}
local world_mt = {__index=world}

local function create_world(sim, lex)
	local _world = C.w_create(sim, lex)
	local obj, var, env = create_env_lex(_world, lex)
	return setmetatable({
		_world=_world,
		_sim=sim,
		_lex=lex,
		obj=obj,
		var=var,
		env=env
	}, world_mt)
end

local function inject(env, world)
	env.world = world
	-- shortcuts
	env.obj = world.obj
	env.var = world.var
	env.env = world.env
	env.template = delegate(world, world.template)
end

function world:template(obj, values)
	local sz = C.w_tpl_size(obj)
	local tpl = ffi.gc(ffi.cast("w_objtpl *", C.malloc(sz)), C.free)
	ffi.fill(tpl, sz)
	local vt = obj.vtemplate
	for varid,val in pairs(values) do
		tpl.defaults[tplidx(varid)] = typing.lua2tvalue(val, vt.bands[varid].type)
	end
	C.w_tpl_create(obj, tpl)
	return tpl
end

function world:swap_env(env)
	local pvec old = ffi.new("struct pvec")
	local pvec new = ffi.new("struct pvec")
	C.w_env_pvec(old, env)
	new.type = old.type
	new.n = old.n
	new.data = C.w_alloc_env(self._world, env)
	C.w_env_swap(self._world, env, new.data)
	return vmath.vec(old), vmath.vec(new)
end

function world:swap_band(vec, varid)
	local pvec old = ffi.new("struct pvec")
	local pvec new = ffi.new("struct pvec")
	C.w_obj_pvec(old, vec, varid)
	new.type = old.type
	new.n = old.n
	new.data = C.w_alloc_band(self._world, vec, varid)
	C.w_obj_swap(self._world, vec, varid, new.data)
	return vmath.vec(old), vmath.vec(new)
end

function world:create_objs(tpl, pos)
	local c_pos, n = copyarray("gridpos[?]", pos)
	local refs = ffi.new("w_objref[?]", n)
	C.w_allocv(self._world, refs, tpl, n, c_pos)
	return refs
end

function world:del_objs(refs)
	local r, n = copyarray("w_objref[?]", refs)
	C.w_deletev(self._world, n, r)
end

local function next_objvec(iter)
	iter.idx = iter.idx+1
	if iter.idx >= iter.max then
		return
	end

	return iter.vecs[iter.idx], iter.idx
end

function world:objvecs(obj)
	local grid = obj.grid
	local vecs = ffi.cast("w_objvec **", grid.data)
	local max = C.grid_max(grid.order)

	return next_objvec, {idx=-1, max=max, vecs=vecs}
end

function world.read1(ref, varid)
	local t = ref.vec.bands[varid].type
	return typing.tvalue2lua(C.sim_obj_read1(ref, varid), t)
end

function world.write1(ref, varid, value)
	local t = ref.vec.bands[varid].type
	C.sim_obj_write1(ref, varid, typing.lua2tvalue(value, t))
end

-------------------------

return {
	create = create_world,
	inject = inject
}
