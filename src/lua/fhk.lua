local model = require "model"
local typing = require "typing"
local alloc = require "alloc"
local aux = require "aux"
local log = require("log").logger
local ffi = require "ffi"
local C = ffi.C

local function copy_cst(check, cst)
	if cst.type == "interval" then
		check.type = C.FHK_RIVAL
		check.rival.min = cst.a
		check.rival.max = cst.b
	elseif cst.type == "set" then
		check.type = C.FHK_BITSET
		check.setmask = cst.mask
	else
		error(string.format("invalid cst type '%s'", cst.type))
	end
end

local function create_checks(checks, fvars)
	local nc = aux.countkeys(checks)

	if nc == 0 then
		return 0, nil
	end

	local ret = ffi.new("struct fhk_check[?]", nc)
	local idx = 0

	for name,cst in pairs(checks) do
		local check = ret+idx
		check.var = fvars[name]
		C.fhk_check_set_cost(check, cst.cost_in, cst.cost_out)
		copy_cst(check.cst, cst)
		idx = idx+1
	end

	return nc, ret
end

local function copy_vars(names, fvars)
	local ret = ffi.new("struct fhk_var *[?]", #names)

	for i,name in ipairs(names) do
		if not fvars[name] then
			error(string.format("Unmapped variable '%s'", name))
		end
		ret[i-1] = fvars[name]
	end

	return #names, ret
end

local function assign_ptrs(G, vars, models)
	local fv, fm = {}, {}
	local nv, nm = 0, 0

	for name,v in pairs(vars) do
		fv[name] = G.vars[nv]
		nv = nv+1
	end

	for name,m in pairs(models) do
		fm[name] = G.models[nm]
		nm = nm+1
	end

	return fv, fm
end

local function build_models(G, arena, fvars, fmodels, models)
	for name,fm in pairs(fmodels) do
		local m = models[name]

		if not m.k or not m.c then
			log:warn("No cost given for model %s - defaulting to k=1, c=2", name)
		end

		C.fhk_model_set_cost(fm, m.k or 1, m.c or 2)
		C.fhk_copy_checks(arena, fm, create_checks(m.checks, fvars))
		C.fhk_copy_params(arena, fm, copy_vars(m.params, fvars))
		C.fhk_copy_returns(arena, fm, copy_vars(m.returns, fvars))
	end
end

local function build_graph(vars, models)
	local arena = alloc.arena_nogc()
	local G = ffi.gc(C.fhk_alloc_graph(arena, aux.countkeys(vars), aux.countkeys(models)),
		function() C.arena_destroy(arena) end)
	local fv, fm = assign_ptrs(G, vars, models)
	build_models(G, arena, fv, fm, models)
	C.fhk_compute_links(arena, G)
	return G, fv, fm, vars, models
end

local function create_models(vars, models, calib)
	calib = calib or {}
	local exf = {}
	local conf = model.config()

	for name,m in pairs(models) do
		conf:reset()
		local atypes = conf:newatypes(#m.params)
		local rtypes = conf:newrtypes(#m.returns)
		for i,n in ipairs(m.params) do atypes[i-1] = typing.promote(vars[n].type.desc) end
		for i,n in ipairs(m.returns) do rtypes[i-1] = typing.promote(vars[n].type.desc) end
		conf.n_coef = #m.coeffs
		conf.calibrated = calib[name] ~= nil

		local def = model.def(m.impl.lang, m.impl.opt):configure(conf)
		local mod = def()

		if mod == ffi.NULL then
			error(string.format("Failed to create model '%s': %s", name, model.error()))
		end

		exf[name] = mod

		local cal = calib[name]
		if cal then
			for i,c in ipairs(m.coeffs) do
				if not cal[c] then
					error(string.format("Missing coefficient '%s' for model '%s'", c, name))
				end

				mod.coefs[i-1] = cal[c]
			end
			mod:calibrate()
		end
	end

	return exf
end

local function newbitmap(n)
	local ret = ffi.gc(C.bm_alloc(n), C.bm_free)
	C.bm_zero(ret, n)
	return ret
end

ffi.metatype("struct fhk_graph", { __index = {
	newvmask = function(self) return newbitmap(self.n_var) end,
	newmmask = function(self) return newbitmap(self.n_mod) end,
	init     = C.fhk_init,
	reset    = C.fhk_reset_mask
}})

--------------------------------------------------------------------------------

local bind_mt = { __call = function(v) self.ref[0] = v end }

local function bindref(ref)
	return setmetatable({ref=ref}, bind_mt)
end

local function bind_ns(newref)
	return setmetatable({}, {
		__index = function(self, k)
			self[k] = newref()
			return self[k]
		end
	})
end

local mapper_mt = { __index = {} }
local subgraph_mt = { __index = {} }

local function create_subgraph(mapper, G, fvars, fmodels)
	return setmetatable({
		G          = G,
		mapper     = mapper,
		fvars      = fvars,
		fmodels    = fmodels
	}, subgraph_mt)
end

local function hook(G, fvars, fmodels, vars, models)
	C.gmap_hook_main(G)

	local mvars, mmods = {}, {}

	for name,var in pairs(vars) do
		local v = {
			name = name,
			type = var.type
		}

		mvars[name] = v
		mvars[tonumber(fvars[name].uidx)] = v
	end

	for name,mod in pairs(models) do
		local m = {
			name = name
		}

		mmods[name] = m
		mmods[tonumber(fmodels[name].uidx)] = m
	end

	local arena = alloc.arena()

	local mapper = setmetatable({
		arena      = arena,
		vars       = mvars,
		models     = mmods,
		virtuals   = require("virtual").virtuals(),
		visible    = {},
		bind       = {
			z      = bind_ns(function() return arena:new("gridpos") end)
		}
	}, mapper_mt)

	mapper.G_subgraph = create_subgraph(mapper, G, fvars, fmodels)
	mapper:bind_main_graph()

	return mapper
end

function mapper_mt.__index:G()
	return self.G_subgraph.G
end

function mapper_mt.__index:getvar(name)
	local v = self.vars[name]

	if not v then
		error(string.format("No such variable: '%s'", name))
	end

	return v
end

function mapper_mt.__index:own(name, owner)
	local v = self:getvar(name)
	
	if v.owner then
		error(string.format("Variable '%s' already has this owner -> %s", v.owner))
	end

	v.owner = owner
end

function mapper_mt.__index:always_visible(x)
	table.insert(self.visible, x)
	return x
end

function mapper_mt.__index:bind_main_graph()
	-- treat each var as computed here
	local G = self:G()
	local mappings = self.arena:new("struct gv_any", G.n_var)

	for i=0, tonumber(G.n_var)-1 do
		local name = self.vars[i].name
		local fv = self.G_subgraph.fvars[name]
		self:init_header(mappings[fv.idx], name, C.GMAP_COMPUTED)
	end

	for i=0, tonumber(G.n_var)-1 do
		C.gmap_bind(G, i, mappings[i])
	end
end

function mapper_mt.__index:subgraph(vmask, mmask)
	return self.G_subgraph:subgraph(vmask, mmask, function(size) return self.arena:malloc(size) end)
end

function mapper_mt.__index:init_header(gv, name, rtype)
	gv.name = name
	gv.flags.rtype = rtype
	gv.flags.vtype = self:getvar(name).type.desc
	return gv
end

function mapper_mt.__index:vec(name, offset, stride, band, idx_bind, v_bind)
	local ret = self:init_header(self.arena:new("struct gv_vec"), name, C.GMAP_VEC)
	ret.flags.offset = offset
	ret.flags.stride = stride
	ret.flags.band = band
	ret.idx_bind = idx_bind
	ret.v_bind = v_bind
	return ret
end

function mapper_mt.__index:grid(name, offset, grid, bind)
	local ret = self:init_header(self.arena:new("struct gv_grid"), name, C.GMAP_ENV)
	ret.flags.offset = offset
	ret.grid = grid
	ret.bind = bind
	return ret
end

function mapper_mt.__index:data(name, ref)
	local ret = self:init_header(self.arena:new("struct gv_data"), name, C.GMAP_DATA)
	ret.ref = ref
	return ret
end

function mapper_mt.__index:interrupt(name, handle)
	local ret = self:init_header(self.arena:new("struct gv_int"), name, C.GMAP_INTERRUPT)
	ret.flags.handle = handle
	return ret
end

function mapper_mt.__index:bind_model(name, mod)
	local model = self.models[name]
	assert(not model.mapping)
	local ret = self.arena:new("struct gmap_model")
	ret.name = name
	ret.mod = mod
	local fm = self.G_subgraph.fmodels[name]
	C.gmap_bind_model(self:G(), fm.idx, ret)
	model.mapping = ret
	model.mapping_mod = mod
	return ret
end

function mapper_mt.__index:bind_models(exf)
	for name,f in pairs(exf) do
		self:bind_model(name, f)
	end
end

--------------------------------------------------------------------------------

local function sg_fnodes(G, mapper)
	local fv = {}
	for i=0, tonumber(G.n_var)-1 do
		local var = mapper.vars[tonumber(G.vars[i].uidx)]
		fv[var.name] = G.vars[i]
	end

	local fm = {}
	for i=0, tonumber(G.n_mod)-1 do
		local model = mapper.models[tonumber(G.models[i].uidx)]
		fm[model.name] = G.models[i]
	end

	return fv, fm
end

function subgraph_mt.__index:subgraph(vmask, mmask, malloc, free)
	if not malloc then
		malloc = C.malloc
		free = C.free
	end
	local size = C.fhk_subgraph_size(self.G, vmask, mmask)
	local H = ffi.cast("struct fhk_graph *", malloc(size))
	if free then ffi.gc(H, free) end
	C.fhk_copy_subgraph(H, self.G, vmask, mmask)
	return create_subgraph(self.mapper, H, sg_fnodes(H, self.mapper))
end

function subgraph_mt.__index:collectvs(names, dest)
	dest = dest or ffi.new("struct fhk_var *[?]", #names)

	for i,name in ipairs(names) do
		if not self.fvars[name] then
			error(string.format("Subgraph doesn't contain '%s'", name))
		end

		dest[i-1] = self.fvars[name]
	end

	return #names, dest
end

function subgraph_mt.__index:collectvmask(vmask)
	local names = {}

	for i=0, tonumber(self.G.n_var)-1 do
		if vmask[i] ~= 0 then
			table.insert(names, self.mapper.vars[tonumber(self.G.vars[i].uidx)].name)
		end
	end

	return names
end

function subgraph_mt.__index:failed()
	local err = self.G.last_error
	local context = {"fhk: solver failed"}

	if err.var ~= ffi.NULL then
		local vname = self.mapper.vars[tonumber(err.var.uidx)].name
		table.insert(context, string.format("\t* Caused by this variable: %s", vname))
	end

	if err.model ~= ffi.NULL then
		local mname = self.mapper.models[tonumber(err.model.uidx)].name
		table.insert(context, string.format("\t* Caused by this model: %s", mname))
	end

	if err.err == C.FHK_MODEL_FAILED then
		table.insert(context, string.format("Model crashed (%d) details below:", C.FHK_MODEL_FAILED))
		table.insert(context, model.error())
	else
		local ecode = {
			[tonumber(C.FHK_SOLVER_FAILED)] = "No solution exists",
			[tonumber(C.FHK_VAR_FAILED)]    = "Failed to resolve given variable",
			[tonumber(C.FHK_RECURSION)]     = "Solver called itself"
		}

		table.insert(context, string.format("\t* Reason: %s (%d)",
			ecode[tonumber(err.err)], err.err))
	end

	error(table.concat(context, "\n"))
end

local function markvs(vmask, nv, fvs, mark)
	mark = mark or 0xff

	for i=0, nv-1 do
		vmask[fvs[i].idx] = mark
	end
end

local function solver_make_res(names, vs)
	local ret = {}
	for i,name in pairs(names) do
		local ptype = typing.promote(vs[name].type.desc)
		ret[name] = {
			idx = i-1,
			ctype = typing.desc_builtin[tonumber(ptype)].ctype .. "*"
		}
	end
	return ret
end

local solver_func_mt = { __index = {} }

function mapper_mt.__index:solver(names)
	return setmetatable({
		mapper   = self,
		names    = names,
		visible  = {},
		mappings = {},
		binds    = {}, -- not used by solver, for sources to put their binding info
		res_info = solver_make_res(names, self.vars)
	}, solver_func_mt)
end

function solver_func_mt.__index:with(...)
	for _,src in ipairs({...}) do
		table.insert(self.visible, src)
	end

	return self
end

function solver_func_mt.__index:from(src)
	self:with(src)
	self.source = src
	return self
end

if C.HAVE_SOLVER_INTERRUPTS == 1 then
	local band, bnot = bit.band, bit.bnot

	function solver_func_mt.__index:wrap_solver(f)
		local sub = self.subgraph
		local gsctx = ffi.gc(C.gs_create_ctx(), C.gs_destroy_ctx)
		local callbacks = self.mapper.virtuals.callbacks

		return function(...)
			C.fhk_clear(sub.G)
			C.gs_enter(gsctx)

			local r = f(...)

			-- TODO: could specialize/generate code for this loop, since this kind of dispatch
			-- probably has horrible performance
			while band(r, bnot(C.GS_ARG_MASK)) ~= 0 do
				assert(band(r, C.GS_INTERRUPT_VIRT) ~= 0)
				local virt = callbacks[tonumber(band(r, C.GS_ARG_MASK))]
				r = virt(gsctx, self)
			end

			if r ~= C.FHK_OK then
				sub:failed()
			end
		end
	end
else
	function solver_func_mt.__index:wrap_solver(f)
		local sub = self.subgraph

		return function(...)
			C.fhk_clear(sub.G)
			local r = f(...)
			if r ~= C.FHK_OK then
				sub:failed()
			end
		end
	end
end

function solver_func_mt.__index:each_visible(f)
	for _,vis in ipairs(self.mapper.visible) do
		f(vis)
	end

	for _,vis in ipairs(self.visible) do
		f(vis)
	end
end

function solver_func_mt.__index:create_mappings()
	self:each_visible(function(vis)
		vis:mark_mappings(function(name)
			if not self.mapper.vars[name] then
				return
			end

			if self.mappings[name] and self.mappings[name] ~= vis then
				error(string.format("Mapping conflict! Variable '%s' is marked by %s and %s",
				name, self.mappings[name], vis))
			end

			self.mappings[name] = vis
		end)
	end)
end

function solver_func_mt.__index:mark_visible(G, vis, vmask, mark)
	mark = mark or 0xff
	for i=0, tonumber(G.n_var)-1 do
		local v = self.mapper.vars[tonumber(G.vars[i].uidx)]
		if self.mappings[v.name] and self.mappings[v.name]:is_visible(vis, v) then
			vmask[i] = mark
		end
	end
end

function solver_func_mt.__index:mark_nonconstant(G, vis, vmask, mark)
	mark = mark or 0xff
	for i=0, tonumber(G.n_var)-1 do
		local v = self.mapper.vars[tonumber(G.vars[i].uidx)]
		if self.mappings[v.name] and not self.mappings[v.name]:is_constant(vis, v) then
			vmask[i] = mark
		end
	end
end

function solver_func_mt.__index:create_visible_mask(mark)
	mark = mark or 0xff
	local G = self.mapper:G()
	local vmask = G:newvmask()

	self:each_visible(function(vis)
		self:mark_visible(G, vis, vmask, mark)
	end)

	return vmask
end

function solver_func_mt.__index:mark_reset_nonconstant(G, reset_v)
	self:each_visible(function(vis)
		self:mark_nonconstant(G, vis, reset_v)
	end)
end

function solver_func_mt.__index:prepare_binds()
	-- Note: potential optimization? here is to not prepare it if it doesn't have any mapped vars
	-- (ie. all vars were cut when solving the subgraph)
	self:each_visible(function(vis)
		if vis.prepare then
			vis:prepare(self)
		end
	end)
end

function solver_func_mt.__index:map_subgraph()
	local G = self.subgraph.G
	C.gmap_hook_subgraph(self.mapper:G(), G)

	for i=0, tonumber(G.n_var)-1 do
		local v = self.mapper.vars[tonumber(G.vars[i].uidx)]
		if self.mappings[v.name] then
			local mp = self.mappings[v.name]:map_var(v, self)
			C.gmap_bind(G, i, ffi.cast("struct gv_any *", mp))
		end
	end
end

function solver_func_mt.__index:create_solver()
	-- (1) make init mask for the full graph
	self:create_mappings()
	local init_v = self:create_visible_mask(ffi.new("fhk_vbmap", {given=1}).u8)
	local nv, ys = self.mapper.G_subgraph:collectvs(self.names)
	markvs(init_v, nv, ys, 0) -- unmark given for roots

	-- (2) reduce on full graph, after this v/mmask contain subgraph selection
	local G = self.mapper:G()
	local vmask = G:newvmask()
	local mmask = G:newmmask()
	G:init(init_v)
	if C.fhk_reduce(G, nv, ys, vmask, mmask) ~= C.FHK_OK then
		self.mapper.G_subgraph:failed()
	end

	-- (3) create subgraph
	local sub = self.mapper:subgraph(vmask, mmask)
	self.subgraph = sub
	local H = sub.G
	local iv = H:newvmask()
	C.fhk_transfer_mask(iv, init_v, vmask, G.n_var)
	H:init(iv)

	-- H isn't shared by any other solver, so we never need iv/init_v again, given/target
	-- flags can't change

	-- (4) create solver on the reduced subgraph
	local solver = ffi.gc(ffi.new("struct fhk_solver"), C.fhk_solver_destroy)
	self.solver = solver
	solver:init(H, nv)
	sub:collectvs(self.names, solver.xs)
	self:mark_reset_nonconstant(H, solver.reset_v)
	solver:compute_reset_mask()

	-- (5) wrap solver: the wrapper should
	--   * reset the graph - only once before calling the solver. this assumes that the "world"
	--     can't change inside the wrapped function (eg. between vector entries).
	--     this enables the solver to only partially reset the graph, which allows fhk to cache
	--     some values between calls to fhk_solve, so it won't needlessly recompute eg.
	--     global values for every vector entry.
	--   * call solver_func. this should solve the whole container (vector, grid, etc.)
	--     this should NOT in any way modify any value fhk can read: globals, any containers
	--     exposed to this solver, model coefficients, ...
	--   * check the result, raise errors or handle virtuals if needed
	self:prepare_binds()
	local solver_func = self.source:create_solver(self)
	self:map_subgraph()
	self.solve = self:wrap_solver(solver_func)

	return self
end

function solver_func_mt.__index:res(name)
	local info = self.res_info[name]
	return (ffi.cast(info.ctype, self.solver.res[info.idx]))
end

function solver_func_mt.__index:bind(x, ...)
	x:bind_solver(self, ...)
end

function solver_func_mt:__call(...)
	return self.solve(...)
end

ffi.metatype("struct fhk_solver", { __index = {
	compute_reset_mask = function(self)
		C.fhk_compute_reset_mask(self.G, self.reset_v, self.reset_m)
	end,

	init = C.fhk_solver_init,
	bind = C.fhk_solver_bind,
	step = C.fhk_solver_step
}})

--------------------------------------------------------------------------------

-- XXX: does this belong here?
local function create_solver1(sf)
	local solver = sf.solver
	local values = ffi.new("pvalue[?]", solver.nv)
	sf._result_buf = values -- attach it to the solver to prevent it from being gc'd
	
	for i=0, tonumber(solver.nv)-1 do
		solver:bind(i, values+i)
	end

	return function()
		return (C.gs_solve_step(solver, 0))
	end
end

local function inject(env)
	local mapper = env.mapper

	env.m2.fhk = {
		bind    = function(x, ...) x:bind(mapper, ...) end,
		virtual = function(name, x, f) return x:virtualize(mapper, name, f) end,
		global  = function(vis, ...) return mapper:always_visible(vis), ... end,
		solve   = function(...)
			local s = mapper:solver({...})
			env.sim:on("sim:compile", function() s:create_solver() end)
			return s
		end,
		typeof  = function(x)
			if not mapper.vars[x] then
				error(string.format("Variable '%s' is not mapped", x))
			end
			return mapper.vars[x].type
		end
	}

	-- shortcut
	env.m2.solve = env.m2.fhk.solve

	env.m2.virtuals = function(vis)
		local vset = mapper.virtuals:vset(vis)
		vset.virtual = function(name, f)
			local ptype = typing.promote(mapper.vars[name].type.desc)
			local tname = typing.desc_builtin[tonumber(ptype)].tname
			return vset:define(name, f, tname)
		end
		return vset
	end
end

return {
	build_graph     = build_graph,
	create_models   = create_models,
	hook            = hook,
	inject          = inject,
	create_solver1  = create_solver1
}
