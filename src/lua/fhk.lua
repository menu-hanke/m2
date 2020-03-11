local model = require "model"
local typing = require "typing"
local alloc = require "alloc"
local virtual = require "virtual"
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

local function solver_failed_m(err)
	local context = {"fhk: solver failed"}

	if err.var ~= nil then
		local mapping = ffi.cast("struct fhkG_mappingV *", err.var.udata)
		if mapping then
			table.insert(context, string.format("\t* Caused by this variable: %s", 
				ffi.string(mapping.name)))
		else
			table.insert(context,
				string.format("\t* Caused by unmapped variable at index %d / %d <%p>",
					err.var.idx, err.var.uidx, err.var))
		end
	end

	if err.model ~= nil then
		local mapping = ffi.cast("struct fhkG_mappingM *", err.model.udata)
		if mapping then
			table.insert(context, string.format("\t* Caused by this model: %s",
				ffi.string(mapping.name)))
		end
	end

	if err.err == C.FHK_MODEL_FAILED then
		table.insert(context, string.format("Model crashed (%d) details below:",
			C.FHK_MODEL_FAILED))
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

-- mapped graphs (see graph.h)
local mgraph_mt = { __index = {} }

local function mgraph(G, mapper, fvars, fmodels)
	return setmetatable({
		G       = G,
		mapper  = mapper,
		fvars   = fvars,
		fmodels = fmodels
	}, mgraph_mt)
end

function mgraph_mt.__index:bind_v(name, mapping)
	C.fhkG_bindV(self.G, self.fvars[name].idx, ffi.cast("struct fhkG_mappingV *", mapping))
end

function mgraph_mt.__index:bind_m(name, mapping)
	C.fhkG_bindM(self.G, self.fmodels[name].idx, mapping)
end

function mgraph_mt.__index:mapping_v(name)
	return ffi.cast("struct fhkG_mappingV *", self.fvars[name].udata)
end

function mgraph_mt.__index:mapping_m(name)
	return ffi.cast("struct fhkG_mappingM *", self.fmodels[name].udata)
end

function mgraph_mt.__index:mark(vmask, names, mark)
	mark = mark or 0xff

	for _,name in ipairs(names) do
		local fv = self.fvars[name]
		if fv then
			vmask[fv.idx] = mark
		end
	end

	return vmask
end

function mgraph_mt.__index:collect(names)
	local ret = ffi.new("struct fhk_var *[?]", #names)

	for i,name in ipairs(names) do
		ret[i-1] = self.fvars[name]
	end

	return #names, ret
end

function mgraph_mt.__index:value_ptr(name)
	local cp = ffi.typeof("$ *", self.mapper:ptypeof(name))
	return ffi.cast(cp, typing.memb_ptr("struct fhk_var", "value", self.fvars[name]))
end

function mgraph_mt.__index:reduce(names, init_v)
	if init_v then
		self.G:init(init_v)
	end

	local vmask = self.G:newvmask()
	local mmask = self.G:newmmask()
	local nv, ys = self:collect(names)

	if C.fhk_reduce(self.G, nv, ys, vmask, mmask) ~= C.FHK_OK then
		solver_failed_m(self.G.last_error)
	end

	return vmask, mmask
end

function mgraph_mt.__index:subgraph(vmask, mmask, malloc, free)
	if not malloc then
		malloc = C.malloc
		free = C.free
	end

	local size = C.fhk_subgraph_size(self.G, vmask, mmask)
	local H = ffi.cast("struct fhk_graph *", malloc(size))
	if free then ffi.gc(H, free) end
	C.fhk_copy_subgraph(H, self.G, vmask, mmask)

	local fvars, fmodels = {}, {}

	for i=0, tonumber(H.n_var)-1 do
		local fv = H.vars+i
		local name = self.mapper.vars[tonumber(fv.uidx)].name
		fvars[name] = fv
	end

	for i=0, tonumber(H.n_mod)-1 do
		local fm = H.models+i
		local name = self.mapper.models[tonumber(fm.uidx)].name
		fmodels[name] = fm
	end

	return mgraph(H, self.mapper, fvars, fmodels)
end

local mapper_mt = { __index = {} }

local function hook(G, fvars, fmodels, xvars)
	local vars = {}
	for name,fv in pairs(fvars) do
		vars[name] = { name = name, type = xvars[name].type }
		vars[tonumber(fv.uidx)] = vars[name]
	end

	local models = {}
	for name,fm in pairs(fmodels) do
		models[name] = { name = name }
		models[tonumber(fm.uidx)] = models[name]
	end

	setmetatable(vars, {
		__index = function(_, name) error(string.format("Variable doesn't exist: %s", name)) end,
		__newindex = function() error("Can't create new variables") end
	})

	setmetatable(models, {
		__index = function(_, name) error(string.format("Model doesn't exist: %s", name)) end,
		__newindex = function() error("Can't create new models") end
	})

	local mapper = setmetatable({
		vars     = vars,
		models   = models,
		arena    = alloc.arena(),
		virtuals = virtual.virtuals(),
		given    = {}
		-- renamers
	}, mapper_mt)

	C.fhkG_hook(G, C.FHKG_HOOK_DEBUG_ONLY)
	local graph = mgraph(G, mapper, fvars, fmodels)
	mapper.graph = graph
	mapper:bind_names()

	return mapper
end

function mapper_mt.__index:mapped(name)
	return rawget(self.vars, name) ~= nil
end

function mapper_mt.__index:typeof(name)
	return self.vars[name].type
end

function mapper_mt.__index:ptypeof(name)
	local ptype = typing.promote(self:typeof(name).desc)
	return ffi.typeof(typing.desc_builtin[tonumber(ptype)].ctype)
end

function mapper_mt.__index:bind_names()
	for name,_ in pairs(self.graph.fvars) do
		local mapping = self.arena:new("struct fhkG_mappingV")
		mapping.flags.resolve = C.FHKG_MAP_COMPUTED
		mapping.flags.type = self:typeof(name).desc
		mapping.name = name
		self.graph:bind_v(name, mapping)
	end
end

function mapper_mt.__index:bind_models(exf)
	for name,mod in pairs(exf) do
		local mapping = self.arena:new("struct fhkG_mappingM")
		mapping.mod = mod
		mapping.name = name
		self.graph:bind_m(name, mapping)
	end
end

function mapper_mt.__index:subgraph(vmask, mmask)
	return self.graph:subgraph(vmask, mmask, function(size) return self.arena:malloc(size) end)
end

--------------------------------------------------------------------------------

local solver_mt = { __index = {} }

function mapper_mt.__index:solver(names)
	return setmetatable({
		mapper = self,
		arena  = self.arena, -- create a new arena if solver needs to be destroyed before mapper?
		names  = names,
		direct = {},
		udata  = {}
	}, solver_mt)
end

-- two ways to use this:
--   * solver:given(y1, y2, ..., yN)
--   * solver:given(mappable [, params])
function solver_mt.__index:given(...)
	local args = {...}

	if type(args[1]) == "string" then
		for _,a in ipairs(args) do
			table.insert(self.direct, a)
		end
	else
		self.udata[args[1]] = args[2] or {}
	end

	return self
end

function solver_mt.__index:over(src)
	self:given(src)
	self.source = src
	return self
end

function solver_mt.__index:merge_udata()
	for mp,p in pairs(self.mapper.given) do
		self.udata[mp] = aux.merge(self.udata[mp] or {}, p)
	end
end

function solver_mt.__index:define_mappings()
	local maps = {}

	for _,m in ipairs(aux.keys(self.udata)) do
		m:define_mappings(self, function(name, map)
			-- TODO: name mangle here
			if self.mapper:mapped(name) then
				if maps[name] and maps[name] ~= m then
					error(string.format("Mapping conflict! Variable '%s' is mapped by %s and %s",
						name, maps[name], m))
				end
			end

			maps[name] = map
		end)
	end

	return maps
end

function solver_mt.__index:create_init_mask_G(maps)
	local graph = self.mapper.graph
	local init_v = graph.G:newvmask()

	-- mark as given all defined mappings
	graph:mark(init_v, aux.keys(maps), ffi.new("fhk_vbmap", {given=1}).u8)

	-- variables mapped directly to graph will always have value
	graph:mark(init_v, self.direct, ffi.new("fhk_vbmap", {given=1, has_value=1}).u8)

	-- zero out the variables we want to solve
	graph:mark(init_v, self.names, 0)

	return init_v
end

function solver_mt.__index:create_direct()
	self.solver = C.fhkG_solver_create(self.G, self.nv, self.ys, self.init_v)
	return self.solver
end

function solver_mt.__index:create_iter(iter)
	-- bitmaps will be calculated later
	self.solver = C.fhkG_solver_create_iter(self.G, self.nv, self.ys, self.init_v,
		ffi.cast("struct fhkG_map_iter *", iter), nil, nil)
	return self.solver
end

function solver_mt.__index:wrap_solver()
	local solve

	if self.source and self.source.wrap_solver then
		solve = self.source:wrap_solver(self)
	else
		solve = self:create_direct()
	end

	local band, bnot = bit.band, bit.bnot
	local callbacks = self.mapper.virtuals.callbacks
	return function(...)
		local r = solve(...)

		while r ~= C.FHK_OK do
			if band(r, C.FHKG_INTERRUPT_V) ~= 0 then
				local virt = callbacks[tonumber(band(r, C.FHKG_HANDLE_MASK))]
				r = virt(self)
			else
				solver_failed_m(self.G.last_error)
			end
		end
	end
end

function solver_mt.__index:create_vars(graph)
	local vp = {}
	if self.solver:is_iter() then
		local binds = self.solver:binds()
		for i,name in ipairs(self.names) do
			vp[name] = ffi.cast(ffi.typeof("$**", self.mapper:ptypeof(name)), binds+(i-1))
		end
	else
		for _,name in ipairs(self.names) do
			vp[name] = graph:value_ptr(name)
		end
	end

	local dp = {}
	for _,name in ipairs(self.direct) do
		dp[name] = graph:value_ptr(name)
	end

	return setmetatable({}, {
		__index = function(_, name) return vp[name][0] end,
		__newindex = function(_, name, value) dp[name][0] = value end
	})
end

function solver_mt.__index:bind_mappings(maps, graph)
	local const = {}

	for name,map in pairs(maps) do
		if graph.fvars[name] then
			local m, c = map()
			-- fill in name&type so the caller doesn't have to, since these will come from
			-- the mapper
			m.name = name
			m.flags.type = self.mapper:typeof(name).desc
			graph:bind_v(name, m)
			if c then table.insert(const, name) end
		end
	end

	return const
end

function solver_mt.__index:create_bitmaps(graph, const)
	local reset_v = graph.G:newvmask()
	local reset_m = graph.G:newmmask()
	graph:mark(reset_v, const, 0xff)
	graph:mark(reset_v, self.direct, 0xff) -- directs are treated as constant
	C.bm_not(reset_v, graph.G.n_var) -- mark NON-constant
	C.fhk_compute_reset_mask(graph.G, reset_v, reset_m)
	return reset_v, reset_m
end

function solver_mt.__index:create_solver()
	self:merge_udata()
	local maps = self:define_mappings()
	local init_v = self:create_init_mask_G(maps)
	local vmask, mmask = self.mapper.graph:reduce(self.names, init_v)
	local graph = self.mapper:subgraph(vmask, mmask)
	C.fhkG_hook(graph.G, C.FHKG_HOOK_ALL)
	self.G = graph.G
	local nv, ys = graph:collect(self.names)
	self.nv = nv
	self.ys = ys
	self.init_v = self.G:newvmask()
	C.fhk_transfer_mask(self.init_v, init_v, vmask, self.mapper.graph.G.n_var)
	self.solver_func = self:wrap_solver()

	if not self.solver then
		error("wrap_solver() didn't create solver")
	end

	self.vars = self:create_vars(graph)
	local const = self:bind_mappings(maps, graph)

	if self.solver:is_iter() then
		local reset_v, reset_m = self:create_bitmaps(graph, const)
		-- make sure they're not gced
		self.___reset_v = reset_v
		self.___reset_m = reset_m
		C.fhkG_solver_set_reset(self.solver, reset_v, reset_m)
	end
end

function solver_mt.__index:bind(x, ...)
	x:bind_solver(self, ...)
end

function solver_mt:__call(...)
	self.solver_func(...)
end

ffi.metatype("struct fhkG_solver", {
	__index = {
		is_iter = C.fhkG_solver_is_iter,
		bind    = C.fhkG_solver_bind,
		binds   = C.fhkG_solver_binds
	},
	
	__gc = C.fhkG_solver_destroy,

	-- Note: just setting __call = C.fhkG_solver_solve results in trace abort with the
	-- message "bad argument type" (I don't know why).
	-- The parentheses prevent tailcalling to C which also causes trace abort
	__call = function(self) return (C.fhkG_solver_solve(self)) end
})

--------------------------------------------------------------------------------

local function inject(env)
	local mapper = env.mapper

	env.m2.fhk = {
		typeof  = aux.delegate(mapper, mapper.typeof),
		config  = function(x, conf)
			if conf.global then mapper.given[x] = conf.global == true and {} or conf.global end
			-- TODO: name mangling config goes here
			return x
		end,
		solve   = function(...)
			local s = mapper:solver({...})
			env.sim:on("sim:compile", function() s:create_solver() end)
			return s
		end
	}

	-- shortcut
	env.m2.solve = env.m2.fhk.solve

	env.m2.virtuals = function(vis)
		local vset = mapper.virtuals:vset(vis)
		vset.virtual = function(name, f)
			local ptype = typing.promote(mapper:typeof(name).desc)
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
}
