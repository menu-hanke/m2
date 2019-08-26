local ffi = require "ffi"
local exec = require "exec"
local typing = require "typing"
local arena = require "arena"
local malloc = require "malloc"
local C = ffi.C

local function copy_ival_cst(check, a, b)
	check.cst.type = C.FHK_RIVAL
	check.cst.rival.min = a
	check.cst.rival.max = b
end

local function copy_set_cst(check, values)
	local mask = 0

	for _,v in ipairs(values) do
		if v<0 or v>63 then
			error(string.format("invalid bitset value: %d", v))
		end

		-- XXX: not sure if lua actually has 64-bit integers,
		-- maybe this should be done in C
		mask = bit.bor(mask, tonumber(C.packenum(v)))
	end

	check.cst.type = C.FHK_BITSET
	check.cst.setmask = mask
end

local function copy_cst(check, cst)
	if cst.type == "ival" then
		copy_ival_cst(check, cst.a, cst.b)
	elseif cst.type == "set" then
		copy_set_cst(check, cst.values)
	else
		error(string.format("invalid cst type '%s'", cst.type))
	end
end

local function create_checks(checks)
	if #checks == 0 then
		return
	end

	local ret = ffi.new("struct fhk_check[?]", #checks)

	for i=0, #checks-1 do
		local c = ret+i
		local check = checks[i+1]
		c.var = check.var.fhk_var
		c.costs[C.FHK_COST_IN] = check.cost_in
		c.costs[C.FHK_COST_OUT] = check.cost_out
		copy_cst(c, check.cst)
	end

	return ret
end

local function copyvars(vs)
	if #vs == 0 then
		return
	end

	local ret = ffi.new("struct fhk_var *[?]", #vs)
	for i,fv in ipairs(vs) do
		ret[i-1] = fv.fhk_var
	end

	return ret
end

local function create_graph(cfg)
	local arena = arena.create()
	local models = collect(cfg.fhk_models)
	local vars = collect(cfg.fhk_vars)
	local G = ffi.gc(C.fhk_alloc_graph(arena, #vars, #models),
		function() C.arena_destroy(arena) end)

	for i,m in ipairs(models) do
		m.fhk_model = C.fhk_get_model(G, i-1)
	end

	for i,v in ipairs(vars) do
		v.fhk_var = C.fhk_get_var(G, i-1)
	end

	for _,m in ipairs(models) do
		local fm = m.fhk_model

		fm.k = m.k or 1
		fm.c = m.c or 1

		if not m.k or not m.c then
			io.stderr:write(string.format("warn: No cost given for model %s - defaulting to 1\n",
				m.name))
		end

		local checks = create_checks(m.checks)
		C.fhk_copy_checks(arena, fm, #m.checks, checks)

		local params = copyvars(m.params)
		C.fhk_copy_params(arena, fm, #m.params, params)

		local returns = copyvars(m.returns)
		C.fhk_copy_returns(arena, fm, #m.returns, returns)
	end

	C.fhk_compute_links(arena, G)

	return G
end

local function create_exf(cfg)
	for _,m in pairs(cfg.fhk_models) do
		m.ex_func = exec.from_model(m)
	end
end

--------------------------------------------------------------------------------

local gmap = {}
local gmap_mt = {__index=gmap}

local function gen_objids(cfg)
	local id = 1
	for _,obj in pairs(cfg.objs) do
		obj.fhk_mapping_id = id
		id = id+1
	end
end

local function create_obj_binds(cfg)
	for _,obj in pairs(cfg.objs) do
		obj.fhk_mapping_bind = ffi.new("w_objref")
	end
end

local function create_z_bind(cfg)
	return ffi.new("gridpos[1]")
end

local function set_gv(gv, name, type)
	gv.name = name
	gv.type.support_type = type
	gv.type.resolve_type = type
	return gv
end

local function map_var(src)
	local ret = set_gv(
		ffi.new("struct gv_var"),
		src.name,
		C.GMAP_VAR
	)

	ret.objid = src.obj.fhk_mapping_id
	ret.wbind = src.obj.fhk_mapping_bind
	ret.varid = src.varid

	return ret
end

local function map_env(src, zbind)
	local ret = set_gv(
		ffi.new("struct gv_env"),
		src.name,
		C.GMAP_ENV
	)

	ret.wenv = src.wenv
	ret.zbind = zbind

	return ret
end

local function map_global(src)
	local ret = set_gv(
		ffi.new("struct gv_global"),
		src.name,
		C.GMAP_GLOBAL
	)

	ret.wglob = src.wglob

	return ret
end

local function map_computed(name)
	return set_gv(
		ffi.new("struct gv_computed"),
		name,
		C.GMAP_COMPUTED
	)
end

local function map_virtual(name, kind, closure, udata, arg)
	local ret = ffi.new("struct gv_virtual")

	ret.name = name
	ret.type.resolve_type = C.GMAP_VIRTUAL

	if kind == "var" then
		ret.type.support_type = C.GMAP_VAR
		ret.var.objid = arg.fhk_mapping_id
	elseif kind == "env" then
		ret.type.support_type = C.GMAP_ENV
		ret.env.wenv = arg.wenv
	elseif kind == "global" then
		ret.type.support_type = C.GMAP_GLOBAL
	else
		assert(false)
	end

	ret.resolve = closure
	ret.udata = udata

	return ret
end

local function bind_mapping(G, fv, mapping)
	fv.fhk_mapping = mapping
	C.gmap_bind(G, fv.fhk_var.idx, ffi.cast("struct gmap_any *", mapping))
end

local function bind_model(G, fm)
	fm.fhk_mapping = ffi.new("struct gmap_model")
	fm.fhk_mapping.name = fm.name
	fm.fhk_mapping.f = fm.ex_func
	C.gmap_bind_model(G, fm.fhk_model.idx, fm.fhk_mapping)
end

local function map_all(G, cfg, zbind)
	for _,obj in pairs(cfg.objs) do
		for name,var in pairs(obj.vars) do
			local fv = cfg.fhk_vars[name]
			if fv then
				bind_mapping(G, fv, map_var(var))
			end
		end
	end

	for name,env in pairs(cfg.envs) do
		local fv = cfg.fhk_vars[name]
		if fv then
			bind_mapping(G, fv, map_env(env))
		end
	end

	for name,glob in pairs(cfg.globals) do
		local fv = cfg.fhk_vars[name]
		if fv then
			bind_mapping(G, fv, map_global(glob))
		end
	end

	for name,fv in pairs(cfg.fhk_vars) do
		if fv.kind == "computed" then
			bind_mapping(G, fv, map_computed(name))
		end
	end
end

local function create_mapping(G, cfg)
	C.gmap_hook(G)
	gen_objids(cfg)
	create_obj_binds(cfg)
	-- TODO: could create zbind here only if there are any envs
	local zbind = create_z_bind()
	map_all(G, cfg, zbind)
	for _,fm in pairs(cfg.fhk_models) do
		bind_model(G, fm)
	end

	return setmetatable({G=G, zbind=zbind}, gmap_mt)
end

local function newbitmap(n)
	local bm = C.bm_alloc(n)
	C.bm_zero(bm, n)
	return bm
end

local function objchange(objid)
	local ret = ffi.new("gmap_change")
	ret.type = C.GMAP_NEW_OBJECT
	ret.objid = objid
	return ret
end

local function zchange(order)
	local ret = ffi.new("gmap_change")
	ret.type = C.GMAP_NEW_Z
	ret.order = order
	return ret
end

local function set_init_vars(vmask, cfg, vars)
	local solve = ffi.new("fhk_vbmap")
	solve.stable = 1

	for _,v in ipairs(vars) do
		local fv = cfg.fhk_vars[v]
		vmask[fv.fhk_var.idx] = solve.u8
	end
end

local function create_obj_init(G, cfg, obj)
	local init_v = newbitmap(G.n_var)
	C.gmap_mark_reachable(G, init_v, objchange(obj.fhk_mapping_id))
	if obj.position_var then
		C.gmap_mark_reachable(G, init_v, zchange(C.POSITION_ORDER));
	end

	local given = ffi.new("fhk_vbmap")
	given.given = 1
	C.bm_and64(init_v, G.n_var, C.bmask8(given.u8))

	local stable = ffi.new("fhk_vbmap")
	stable.stable = 1
	C.bm_or64(init_v, G.n_var, C.bmask8(stable.u8))

	return init_v
end

local function create_obj_reset(G, obj)
	local reset_v, reset_m = newbitmap(G.n_var), newbitmap(G.n_mod)
	C.gmap_mark_supported(G, reset_v, objchange(obj.fhk_mapping_id))
	if obj.z_order then
		C.gmap_mark_supported(G, reset_v, zchange(obj.z_order))
	end
	C.gmap_make_reset_masks(G, reset_v, reset_m)
	return reset_v, reset_m
end

function gmap:create_vec_solver(cfg, obj, vars)
	local nv = #vars
	local init_v = create_obj_init(self.G, cfg, obj)
	set_init_vars(init_v, cfg, vars)
	local reset_v, reset_m = create_obj_reset(self.G, obj)
	local xs = malloc.new("struct fhk_var *", nv)
	local types = malloc.new("type", nv)

	local arg = ffi.gc(ffi.new("struct gs_vec_args"), function()
		C.free(init_v)
		C.free(reset_v)
		C.free(reset_m)
		C.free(xs)
		C.free(types)
	end)

	for i,v in ipairs(vars) do
		xs[i-1] = cfg.fhk_vars[v].fhk_var
		types[i-1] = obj.vars[v].type
	end

	arg.G = self.G
	arg.wobj = obj.wobj
	arg.wbind = obj.fhk_mapping_bind
	arg.zbind = self.zbind
	arg.reset_v = reset_v
	arg.reset_m = reset_m
	arg.nv = nv
	arg.xs = xs
	arg.types = types

	local res = ffi.new("void *[?]", nv)

	return function(vec, d)
		for i,v in ipairs(d) do
			res[i-1] = v.data
		end

		C.gmap_init(arg.G, init_v)
		C.gmap_solve_vec(vec, res, arg)
	end
end

--------------------------------------------------------------------------------

local function wrap_closure(type, closure)
	-- Note: this is hacky and very slow.
	-- Don't use lua virtuals for other than testing,
	-- use C callbacks for performance

	local ptype = C.tpromote(type)
	local pvfield = typing.pvalue_map[tonumber(ptype)]
	return ffi.cast("uint64_t (*)(void *)", function(udata)
		local r = ffi.new("pvalue")
		r[pvfield] = closure(udata)
		return r.b
	end)
end

local function inject(env, mapping, cfg)

	env.fhk = {

		vec_solver = function(obj, vars)
			return mapping:create_vec_solver(cfg, obj, vars)
		end,

		virtual = function(arg, kind, name, closure, udata)
			local fv = cfg.fhk_vars[name]
			if type(closure) == "function" then
				closure = wrap_closure(fv.src.type, closure)
			end
			local virt = map_virtual(name, kind, closure, udata, arg)
			bind_mapping(mapping.G, fv, virt)
		end,

		gvirtual = function(...)
			return env.fhk.virtual(nil, "global", ...)
		end

	}

	env._obj_meta.__index.vec_solver = env.fhk.vec_solver

	env._obj_meta.__index.virtual = function(self, ...)
		return env.fhk.virtual(self, "var", ...)
	end

	env._obj_meta.__index.bind = function(self, ref)
		ffi.copy(self.fhk_mapping_bind, ref, ffi.sizeof("w_objref"))
	end

	env._env_meta.__index.virtual = function(self, ...)
		return env.fhk.virtual(self, "env", ...)
	end
end

return {
	create_graph   = create_graph,
	create_exf     = create_exf,
	create_mapping = create_mapping,
	inject         = inject
}
