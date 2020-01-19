local model = require "model"
local typing = require "typing"
local alloc = require "alloc"
local aux = require "aux"
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
			io.stderr:write(string.format(
				"warn: No cost given for model %s - defaulting to k=1 c=2\n", name))
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
	newvmask         = function(self) return newbitmap(self.n_var) end,
	newmmask         = function(self) return newbitmap(self.n_mod) end,
	init             = C.fhk_init,
	reset            = C.fhk_reset_mask,
	mark_visible     = C.gmap_mark_visible,
	mark_nonconstant = C.gmap_mark_nonconstant
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
	C.gmap_hook(G)

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
		virtuals   = {},
		bind       = {
			z      = bind_ns(function() return arena:new("gridpos") end)
		}
	}, mapper_mt)

	mapper.G_subgraph = create_subgraph(mapper, G, fvars, fmodels)

	return mapper
end

function mapper_mt.__index:G()
	return self.G_subgraph.G
end

function mapper_mt.__index:new_objid()
	if not self._next_objid then
		self._next_objid = 1ULL
	end

	if self._next_objid == 0 then
		error("Ran out of objid bits, maybe create less objects")
	end

	-- Note: this is not performance sensitive, so if the 64 obj limit becomes a problem,
	-- then objs can be implemented in gmap as objid array.
	-- A bitmask is just a much simpler way to do it

	local ret = self._next_objid
	self._next_objid = bit.lshift(self._next_objid, 1)
	return ret
end

function mapper_mt.__index:bind_mapping(mapping, name)
	local v = self.vars[name]
	if not v then
		error(string.format("Can't bind mapping '%s': there is no such variable", name))
	end
	if v.mapping then
		error(string.format("Variable '%s' already has this mapping -> %s", name, v.mapping))
	end

	mapping.name = name
	mapping.flags.type = v.type.desc
	local fv = self.G_subgraph.fvars[name]
	C.gmap_bind(self:G(), fv.idx, ffi.cast("struct gmap_any *", mapping))
	v.mapping = mapping
	return mapping
end

function mapper_mt.__index:vcomponent(name, offset, stride, band, offset_bind, idx_bind, v_bind)
	local ret = self.arena:new("struct gv_vcomponent")
	ret.resolve = C.gmap_res_vec
	ret.flags.offset = offset
	ret.flags.stride = stride
	ret.flags.band = band
	ret.offset_bind = offset_bind
	ret.idx_bind = idx_bind
	ret.v_bind = v_bind
	return self:bind_mapping(ret, name)
end

function mapper_mt.__index:grid(name, offset, grid, bind)
	local ret = self.arena:new("struct gv_grid")
	ret.resolve = C.gmap_res_grid
	ret.flags.offset = offset
	ret.grid = grid
	ret.bind = bind
	return self:bind_mapping(ret, name)
end

function mapper_mt.__index:data(name, ref)
	local ret = self.arena:new("struct gv_data")
	ret.resolve = C.gmap_res_data
	ret.ref = ref
	return self:bind_mapping(ret, name)
end

function mapper_mt.__index:computed(name)
	local ret = self.arena:new("struct gmap_any")
	ret.resolve = nil
	ret.supp.is_visible = nil
	ret.supp.is_constant = nil
	self:bind_mapping(ret, name)
end

function mapper_mt.__index:lazy_bind_vars(names)
	for _,name in ipairs(names) do
		if not self.vars[name].mapping then
			self:computed(name)
		end
	end
end

if C.HAVE_SOLVER_INTERRUPTS == 1 then
	function mapper_mt.__index:wrap_virtual(name, func)
		local ptype = typing.promote(self.vars[name].type.desc)
		local tname = typing.desc_builtin[tonumber(ptype)].tname

		return function(ctx)
			local ret = ffi.new("pvalue")
			ret[tname] = func()
			return tonumber(C.gs_resume1(ctx, ret))
		end
	end

	function mapper_mt.__index:virtual(name, func)
		local ret = self.arena:new("struct gs_virt")
		ret.resolve = C.gs_res_virt
		ret.handle = #self.virtuals + 1
		self.virtuals[ret.handle] = self:wrap_virtual(name, func)
		return self:bind_mapping(ret, name)
	end

	function mapper_mt.__index:lazy(name, func)
		local handle = #self.virtuals + 1
		C.gs_lazy(self.vars[name].mapping.lazy, handle)
		self.virtuals[handle] = function(ctx)
			func()
			return tonumber(C.gs_resume0(ctx))
		end
	end
else
	function mapper_mt.__index:virtual()
		error("No virtual support -- compile with SOLVER_INTERRUPTS=on")
	end

	function mapper_mt.__index:lazy()
		error("No lazy support -- compile with SOLVER_INTERRUPTS=on")
	end
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

function subgraph_mt.__index:subgraph(vmask, mmask)
	local size = C.fhk_subgraph_size(self.G, vmask, mmask)
	local H = ffi.gc(ffi.cast("struct fhk_graph *", C.malloc(size)), C.free)
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

local function make_solver_vmask(G, vmask, nv, fvs)
	local given = ffi.new("fhk_vbmap")
	given.given = 1
	C.bm_and64(vmask, G.n_var, C.bmask8(given.u8))

	-- clear given bit for targets
	markvs(vmask, nv, fvs, 0)
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
		local virtuals = self.mapper.virtuals

		return function(...)
			C.fhk_clear(sub.G)
			C.gs_enter(gsctx)

			local r = f(...)

			-- TODO: could specialize/generate code for this loop, since this kind of dispatch
			-- probably has horrible performance
			while band(r, bnot(C.GS_ARG_MASK)) ~= 0 do
				assert(band(r, C.GS_INTERRUPT_VIRT + C.GS_INTERRUPT_LAZY) ~= 0)
				local virt = virtuals[tonumber(band(r, C.GS_ARG_MASK))]
				r = virt(gsctx)
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

function solver_func_mt.__index:mark_visible(init_v)
	for _,vis in ipairs(self.visible) do
		vis:mark_visible(self.mapper, self.mapper:G(), init_v)
	end
end

function solver_func_mt.__index:create_solver()
	-- (1) make init mask for the full graph
	local mapper = self.mapper
	local G = mapper:G()
	local init_v = G:newvmask()
	self:mark_visible(init_v)
	local nv, ys = mapper.G_subgraph:collectvs(self.names)
	make_solver_vmask(G, init_v, nv, ys)

	-- (2) reduce on full graph, after this v/mmask contain subgraph selection
	local vmask = G:newvmask()
	local mmask = G:newmmask()
	G:init(init_v)
	if C.fhk_reduce(G, nv, ys, vmask, mmask) ~= C.FHK_OK then
		mapper.G_subgraph:failed()
	end

	-- make sure everything is bound before creating the subgraph, since creating it copies udata
	-- pointers, so later modifications wouldn't show in the subgraph
	local ynames = mapper.G_subgraph:collectvmask(vmask)
	mapper:lazy_bind_vars(ynames)

	-- (3) create subgraph
	local sub = mapper.G_subgraph:subgraph(vmask, mmask)
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
	self.source:mark_nonconstant(mapper, H, solver.reset_v)
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
	local solver_func = self.source:solver_func(mapper, solver)
	self.solve = self:wrap_solver(solver_func)

	return self
end

function solver_func_mt.__index:res(name)
	local info = self.res_info[name]
	return (ffi.cast(info.ctype, self.solver.res[info.idx]))
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

local function cast_any(f)
	return function(self, ...)
		return f(ffi.cast("struct gmap_any *", self), ...)
	end
end

local support = {
	var    = cast_any(C.gmap_supp_obj_var),
	env    = cast_any(C.gmap_supp_grid_env),
	global = cast_any(C.gmap_supp_global)
}

--------------------------------------------------------------------------------

local rebind = function(sim, solver, n)
	local res_size = n * ffi.sizeof("pvalue")

	for i=0, tonumber(solver.nv)-1 do
		local res = C.sim_alloc(sim, res_size, ffi.alignof("pvalue"), C.SIM_FRAME)
		solver:bind(i, res)
	end
end

local function inject(env, mapper)
	env.fhk = {
		bind    = function(x, ...) x:bind(mapper, ...) end,
		expose  = function(x) x:expose(mapper) return x end,
		virtual = function(name, x, f) return x:virtualize(mapper, name, f) end,
		solve   = function(...)
			local s = mapper:solver({...})
			env.on("sim:compile", function() s:create_solver() end)
			return s
		end,
		typeof  = function(x)
			if not mapper.vars[x] then
				error(string.format("Variable '%s' is not mapped", x))
			end
			return mapper.vars[x].type
		end
	}
end

return {
	build_graph     = build_graph,
	create_models   = create_models,
	hook            = hook,
	support         = support,
	inject          = inject,
	rebind          = rebind
}
