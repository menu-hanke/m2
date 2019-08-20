local ffi = require "ffi"
local exec = require "exec"
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

local function create_params(params)
	if #params == 0 then
		return
	end

	local ret = ffi.new("struct fhk_var *[?]", #params)
	for i,p in ipairs(params) do
		ret[i-1] = p.fhk_var
	end

	return ret
end

local function create_models(models)
	if #models == 0 then
		return
	end

	local ret = ffi.new("struct fhk_model *[?]", #models)
	for i,m in ipairs(models) do
		ret[i-1] = m.fhk_model
	end

	return ret
end

local function retind(returns, y)
	-- we could build a lookup table here to avoid iterating but almost all models
	-- have 1-2 returns so it really doesn't matter
	for i,x in ipairs(returns) do
		if y == x then
			return i
		end
	end

	assert(false)
end

local function create_graph(cfg)
	local arena = C.arena_create(4096)

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
		C.fhk_alloc_checks(arena, fm, #m.checks, checks)

		local params = create_params(m.params)
		C.fhk_alloc_params(arena, fm, #m.params, params)

		C.fhk_alloc_returns(arena, fm, #m.returns)
	end

	for _,v in ipairs(vars) do
		local fv = v.fhk_var

		local models = create_models(v.models)
		C.fhk_alloc_models(arena, fv, #v.models, models)

		for i,m in ipairs(v.models) do
			C.fhk_link_ret(m.fhk_model, fv, retind(m.returns, v)-1, i-1)
		end
	end

	cfg.G = G
	return G
end

local function create_exf(cfg)
	for _,m in pairs(cfg.fhk_models) do
		m.ex_func = exec.from_model(m)
	end
end

local function create_ugraph(G, cfg)
	local u = ffi.gc(C.u_create(G), C.u_destroy)

	for name,fv in pairs(cfg.fhk_vars) do
		if fv.kind == "computed" then
			C.u_add_comp(u, fv.fhk_var, name)
		end
	end

	for name,obj in pairs(cfg.objs) do
		local uobj = C.u_add_obj(u, obj.wobj, name)
		obj.uobj = uobj

		for vname,var in pairs(obj.vars) do
			local fv = cfg.fhk_vars[vname]
			if fv then
				C.u_add_var(u, uobj, var.varid, fv.fhk_var, vname)
			end
		end
	end

	for name,env in pairs(cfg.envs) do
		local fv = cfg.fhk_vars[name]
		if fv then
			env.uenv = C.u_add_env(u, env.wenv, fv.fhk_var, name)
		end
	end

	for name,g in pairs(cfg.globals) do
		local fv = cfg.fhk_vars[name]
		if fv then
			fv.uglob = C.u_add_global(u, g.wglob, fv.fhk_var, name)
		end
	end

	for _,fm in pairs(cfg.fhk_models) do
		C.u_add_model(u, fm.ex_func, fm.fhk_model, fm.name)
	end

	cfg.ugraph = u
	return u
end

-------------------------

local function newbitmap(n)
	local bm = ffi.gc(C.bm_alloc(n), C.bm_free)
	C.bm_zero(bm, n)
	return bm
end

local function objv_reset_bitmaps(G, ugraph, obj)
	local reset_v, reset_m = newbitmap(G.n_var), newbitmap(G.n_mod)
	C.u_mark_obj(reset_v, obj.uobj)
	local order = obj.wgrid and obj.wgrid.order or 0
	C.u_mark_envs_z(reset_v, ugraph, order)
	C.u_reset_mark(ugraph, reset_v, reset_m)
	return reset_v, reset_m
end

local function objv_init_bitmap(G, ugraph, obj, vars)
	local init_v = newbitmap(G.n_var)

	C.u_init_given_obj(init_v, obj.uobj)
	C.u_init_given_globals(init_v, ugraph)
	C.u_init_given_envs(init_v, ugraph)

	for _,fv in ipairs(vars) do
		C.u_init_solve(init_v, fv.fhk_var)
	end

	-- Note: unstable vars aren't implemented yet at all (outside fhk) so this bit must
	-- be always set
	local stable = ffi.new("fhk_vbmap")
	stable.stable = 1
	C.bm_or64(init_v, G.n_var, C.bmask8(stable.u8))

	return init_v
end

local function vars_xs(vars)
	local ret = ffi.new("struct fhk_var *[?]", #vars)
	for i,fv in ipairs(vars) do
		ret[i-1] = fv.fhk_var
	end
	return ret
end

local function vars_types(vars)
	local ret = ffi.new("type[?]", #vars)
	for i,fv in ipairs(vars) do
		ret[i-1] = fv.src.type
	end
	return ret
end

local function create_obj_solver(G, ugraph, obj, vars)
	local uobj = obj.uobj
	local init_v = objv_init_bitmap(G, ugraph, obj, vars)
	local reset_v, reset_m = objv_reset_bitmaps(G, ugraph, obj)
	local nv = #vars
	local xs = vars_xs(vars)
	local res = ffi.new("void *[?]", nv)
	local types = vars_types(vars)

	return function(v, dest)
		C.u_graph_init(ugraph, init_v)
		for i=0, nv-1 do
			res[i] = dest[i+1]
		end
		C.u_solve_vec(ugraph, uobj, reset_v, reset_m, v, nv, xs, res, types)
		return res
	end
end

-------------------------

local function inject(env, cfg, G, ugraph)
	env.fhk = {

		obj_solver = function(obj, vars)
			local xs = {}
			for i,name in ipairs(vars) do
				xs[i] = cfg.fhk_vars[name]
				assert(xs[i])
			end

			return create_obj_solver(G, ugraph, obj, xs)
		end

	}

	env._obj_meta.__index.vsolver = env.fhk.obj_solver
end

return {
	create_graph  = create_graph,
	create_exf    = create_exf,
	create_ugraph = create_ugraph,
	inject        = inject
}
