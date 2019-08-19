local ffi = require "ffi"
local vmath = require "vmath"
local typing = require "typing"
local C = ffi.C

ffi.cdef [[
	void *malloc(size_t size);
	void free(void *ptr);
]]

-------------------------

local objvec = {}

function objvec:band(varid, data)
	local band = self.bands[varid]
	return vmath.vec(data or band.data, band.type, self.n_used)
end

ffi.metatype("w_objvec", {__index=objvec})

-------------------------

local objgrid = {}

local function next_objvec(iter)
	iter.idx = iter.idx+1
	if iter.idx >= iter.max then
		return
	end

	return iter.vecs[iter.idx], iter.idx
end

function objgrid:vecs()
	local grid = self.grid
	local vecs = ffi.cast("w_objvec **", grid.data)
	local max = C.grid_max(grid.order)

	return next_objvec, {idx=-1, max=max, vecs=vecs}
end

ffi.metatype("w_objgrid", {__index=objgrid})

-------------------------

local env = {}

function env:vec(data)
	return vmath.vec(data or self.grid.data, self.type, C.grid_max(self.grid.order))
end

ffi.metatype("w_env", {__index=env})

-------------------------

local function read1(ref, varid)
	local t = ref.vec.bands[varid].type
	return typing.tvalue2lua(C.w_obj_read1(ref, varid), t)
end

local function write1(ref, varid, value)
	local t = ref.vec.bands[varid].type
	C.w_obj_write1(ref, varid, typing.lua2tvalue(value, t))
end

ffi.metatype("w_objref", {__index=read1, __newindex=write1})

-------------------------

local glob = {}

function glob:read()
	return typing.tvalue2lua(self.value, self.type)
end

function glob:write(v)
	self.value = typing.lua2tvalue(v, self.type)
end

ffi.metatype("w_global", {__index=glob})

-------------------------

local function gen_refs(vec, pos, n)
	local ret = ffi.new("w_objref[?]", n)
	for i=0, tonumber(n)-1 do
		ret[i].vec = vec
		ret[i].idx = pos+i
	end
	return ret
end

local world = {
	create_objvec    = function(self, obj)
		return C.w_obj_create_vec(self, obj.wobj)
	end,
	alloc_objvec     = function(self, vec, tpl, n)
		local pos = C.w_objvec_alloc(self, vec, tpl, n)
		return gen_refs(vec, pos, n)
	end,
	alloc_env        = function(self, env)
		return env.wenv:vec(C.w_create_env_data(self, env.wenv))
	end,
	alloc_band       = function(self, vec, varid)
		return vec:band(varid, C.w_objvec_create_band(self, vec, varid))
	end,
	swap_env         = function(self, env, vec)
		C.w_env_swap(self, env.wenv, vec.data)
	end,
	swap_band        = function(self, ovec, varid, vec)
		C.w_obj_swap(self, ovec, varid, vec.data)
	end
}

function world:create_grid_objs(wgrid, tpl, pos)
	local c_pos, n = copyarray("gridpos[?]", pos)
	local refs = ffi.new("w_objref[?]", n)
	C.w_objgrid_alloc(self, refs, wgrid, tpl, n, c_pos)
	return refs
end

function world:del_objs(refs)
	local r, n = copyarray("w_objref[?]", refs)
	C.w_objref_delete(self, n, r)
end

ffi.metatype("world", {__index=world})

-------------------------

local function define_obj(w, src)
	local vars = collect(src.vars)
	local vtypes = ffi.new("type[?]", #vars)
	local zband = -1

	-- Note: this also fixed the var ids
	for i=0, #vars-1 do
		local var = vars[i+1]
		vtypes[i] = var.type
		var.varid = i
		if var == src.position_var then
			zband = i
		end
	end

	local obj = C.w_define_obj(w, #vars, vtypes)
	obj.z_band = zband

	local grid

	if src.z_order then
		grid = C.w_define_objgrid(w, obj, src.z_order)
	end

	return obj, grid
end

local function define_env(w, src)
	return C.w_define_env(w, src.type, src.z_order)
end

local function define_global(w, src)
	return C.w_define_global(w, src.type)
end

local function define(cfg, world)
	for name,obj in pairs(cfg.objs) do
		local wobj, wgrid = define_obj(world, obj)
		obj.wobj = wobj
		obj.wgrid = wgrid
	end

	for name,env in pairs(cfg.envs) do
		local wenv = define_env(world, env)
		env.wenv = wenv
	end

	for name,glob in pairs(cfg.globals) do
		local wglob = define_global(world, glob)
		glob.wglob = wglob
	end
end

local function create_template(obj, values)
	local wobj = obj.wobj
	local sz = C.w_tpl_size(wobj)
	local tpl = ffi.gc(ffi.cast("w_objtpl *", C.malloc(sz)), C.free)
	ffi.fill(tpl, sz)
	local vt = wobj.vtemplate
	for name,val in pairs(values) do
		local varid = obj.vars[name].varid
		tpl.defaults[varid] = typing.lua2tvalue(val, vt.bands[varid].type)
	end
	C.w_tpl_create(wobj, tpl)
	return tpl
end


local function inject(env, world)
	env.world = world
	env._obj_meta.__index.template = create_template
	env._obj_meta.__index.vecs = function(self) return self.wgrid:vecs() end
	env._env_meta.__index.vec = function(self, data) return self.wenv:vec(data) end
end

-------------------------

return {
	create = C.w_create,
	define = define,
	inject = inject
}
