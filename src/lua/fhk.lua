local env = require "env"
local typing = require "typing"
local misc = require "misc"
local alloc = require "alloc"
local virtual = require "virtual"
local model = require "model"
local log = require("log").logger
local ffi = require "ffi"
local C = ffi.C

local band = bit.band

--------------------------------------------------------------------------------
-- reading & defining graphs

local gdef_mt = { __index = {} }

local function gdef()
	return setmetatable({
		models  = {},
		hints   = {},
		classes = {},
		costs   = {},
		calibs  = {}
	}, gdef_mt)
end

local function totable(x)
	return type(x) ~= "table" and {x} or x
end

function gdef_mt.__index:model(name, def)
	if self.models[name] then
		error(string.format("Duplicate definition of model '%s'", name))
	end

	local checks = {}
	if def.checks then
		for var,cst in pairs(def.checks) do
			local check

			if type(var) == "number" then
				-- TODO: helper function to generate these:
				-- {name, var, cst}
				check = {
					name = cst.name,
					var  = cst.var,
					cst  = cst.cst
				}
			else
				check = {
					name = var,
					var  = var,
					cst  = type(cst) == "string" and self:any(cst) or cst
				}
			end

			table.insert(checks, check)
		end
	end

	local impl = def.impl
	if type(impl) == "string" then
		local lang, opt = impl:match("^([^:]+)::(.+)$")
		if not lang then
			error(string.format("Invalid format: %s", impl))
		end
		impl = {lang=lang, opt=opt}
	end

	self.models[name] = {
		name    = name,
		params  = totable(def.params or {}),
		returns = totable(def.returns or {}),
		coeffs  = totable(def.coeffs or {}),
		checks  = checks,
		impl    = impl
	}
end

function gdef_mt.__index:cost(name, cost)
	self.costs[name] = self.costs[name] or { checks={} }
	if cost.k then self.costs[name].k = cost.k end
	if cost.c then self.costs[name].c = cost.c end
	if cost.checks then misc.merge(self.costs[name].checks, cost.checks) end
end

function gdef_mt.__index:calib(name, calib)
	self.calibs[name] = misc.merge(self.calibs[name] or {}, calib)
end

-- classes
function gdef_mt.__index:class(name, def)
	self.classes[name] = self.classes[name] or typing.class()
	misc.merge(self.classes[name], def)
end

local function getclass(def, var)
	local class = (def.hints[var] and def.hints[var].class) or error(
		string.format("Indirect mask value '%s', but no hint (for var '%s')", v, var))
	return def.classes[class] or error(
		string.format("Missing classification '%s' of var '%s'", class, var))
end

local function setmask(def, var, values)
	local mask = 0ULL

	for k,v in pairs(values) do
		if type(v) == "string" then
			local class = getclass(def, var)
			v = class[v] or error(string.format("Missing mask value '%s' (in class '%s' of var '%s')",
				v, def.hints[var].class, var))
		else
			v = v^2ULL
		end

		mask = bit.bor(mask, v)
	end

	return mask
end

-- constraints
function gdef_mt.__index:any(...)
	local values = {...}
	return function(cst, var)
		cst.type = C.FHK_BITSET
		cst.setmask = setmask(self, var, values)
	end
end

function gdef_mt.__index:none(...)
	local values = {...}
	return function(cst, var)
		cst.type = C.FHK_BITSET
		cst.setmask = bit.bnot(setmask(self, var, values))
	end
end

function gdef_mt.__index:between(a, b)
	return function(cst)
		cst.type = C.FHK_RIVAL
		cst.rival.min = a or -math.huge
		cst.rival.max = b or math.huge
	end
end

-- hints
local vhint_mt = {}

local function vhint(x)
	return setmetatable(x, vhint_mt)
end

function vhint_mt.__mul(left, right)
	if type(right) == "table" then
		left, right = right, left
	end

	local ret = misc.merge({}, left)

	if type(right) == "string" then
		ret.type = right
	else
		misc.merge(ret, right)
	end

	return vhint(ret)
end

function gdef_mt.__index:hint(name, hint)
	self.hints[name] = misc.merge(
		self.hints[name] or {},
		type(hint) == "string" and vhint({type=hint}) or hint
	)
end

-- this gives a dsl-like environment that can be used in config files
local function def_env(def)

	local function calib(cs)
		for name,c in pairs(cs) do
			def:calib(name, c)
		end
	end

	local function cost(cs)
		for name,c in pairs(cs) do
			def:cost(name, c)
		end
	end

	local function hint(x, p)
		if type(x) == "string" then
			def:hint(x, p)
		else -- type(x) == "table"
			for k,v in pairs(x) do
				def:hint(k, v)
			end
		end
	end

	local denv = setmetatable({
		calib      = calib,
		read_calib = function(fname) calib(misc.readjson(fname)) end,
		cost       = cost,
		read_cost  = function(fname) cost(misc.readjson(fname)) end,
		model      = env.namespace(misc.delegate(def, def.model)),
		class      = env.namespace(misc.delegate(def, def.class)),
		any        = misc.delegate(def, def.any),
		none       = misc.delegate(def, def.none),
		between    = misc.delegate(def, def.between),
		oftype     = function(typ) return vhint({type=typ}) end,
		ofclass    = function(cls) return vhint({class=cls}) end,
		hint       = hint
	}, { __index=_G })

	denv.read = function(fname) return env.read(denv, fname) end
	return denv
end

--------------------
-- build graph

local function var_set(def)
	local vars = {}

	for _,m in pairs(def.models) do
		for _,p in ipairs(m.params) do vars[p] = true end
		for _,c in ipairs(m.checks) do vars[c.var] = true end
		for _,r in ipairs(m.returns) do vars[r] = true end
	end

	return vars
end

local function assign_ptrs(G, vars, models)
	local fv, fm = {}, {}
	local nv, nm = 0, 0

	for name,_ in pairs(vars) do
		fv[name] = G.vars[nv]
		nv = nv+1
	end

	for name,_ in pairs(models) do
		fm[name] = G.models[nm]
		nm = nm+1
	end

	return fv, fm
end

local function create_checks(checks, fvars, costs)
	if #checks == 0 then
		return 0, nil
	end

	local ret = ffi.new("struct fhk_check[?]", #checks)

	for i,check in ipairs(checks) do
		local ck = ret+(i-1)
		ck.var = fvars[check.var]
		check.cst(ck.cst, check.var)

		local cost = costs and costs[check.name]
		local cin = cost and cost.cost_in or 0
		local cout = cost and cost.cost_out or math.huge
		if cin > cout then
			error(string.format("in cost higher than out cost: %f>%f (in check '%s' of var '%s')",
				cin, cout, check.name, check.var))
		end

		C.fhk_check_set_cost(ck, cin, cout)
	end

	return #checks, ret
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

local function build_models(fvars, fmodels, def, arena)
	for name,fm in pairs(fmodels) do
		local k = def.costs[name] and def.costs[name].k
		local c = def.costs[name] and def.costs[name].c

		if not k or not c then
			k = k or 1
			c = c or 2
			log:warn("No cost given for model %s - defaulting to k=%f, c=%f", name, k, c)
		end

		C.fhk_model_set_cost(fm, k, c)

		local m = def.models[name]
		C.fhk_copy_checks(arena, fm,
			create_checks(m.checks, fvars, def.costs[name] and def.costs[name].checks))
		C.fhk_copy_params(arena, fm, copy_vars(m.params, fvars))
		C.fhk_copy_returns(arena, fm, copy_vars(m.returns, fvars))
	end
end

local function build_graph(def, arena)
	local gc_arena = not arena
	arena = arena or alloc.arena_nogc()

	local vars = var_set(def)
	local G = C.fhk_alloc_graph(arena, misc.countkeys(vars), misc.countkeys(def.models))

	if gc_arena then
		ffi.gc(G, function() C.arena_destroy(arena) end)
	end

	local fv, fm = assign_ptrs(G, vars, def.models)
	build_models(fv, fm, def, arena)
	C.fhk_compute_links(arena, G)
	return G, fv, fm
end

-- not sure where to put these

local function create_model(mod, mapper, calibrated, conf)
	if conf then
		conf:reset()
	else
		conf = model.config()
	end

	local atypes = conf:newatypes(#mod.params)
	local rtypes = conf:newrtypes(#mod.returns)

	for i,name in ipairs(mod.params) do
		atypes[i-1] = mapper:typeof(name).desc
	end

	for i,name in ipairs(mod.returns) do
		rtypes[i-1] = mapper:typeof(name).desc
	end

	conf.n_coef = #mod.coeffs
	conf.calibrated = calibrated

	local def = model.def(mod.impl.lang, mod.impl.opt):configure(conf)
	local mod = def()

	if mod == ffi.NULL then
		error(string.format("Failed to create model '%s': %s", name, model.error()))
	end

	return mod
end

local function calibrate_model(mod, cal)
	for i,c in ipairs(mod.coeffs) do
		if not cal[c] then
			error(string.format("Missing coefficient '%s' for model '%s'", c, name))
		end

		mod.coefs[i-1] = cal[c]
	end

	mod:calibrate()
end

local function calibrator(calibs)
	return function(name)
		local cal = calibs[name]
		return cal and function(model)
			calibrate_model(model, cal)
		end
	end
end

--------------------------------------------------------------------------------
-- fhk graph

local function newbitmap(n)
	local ret = ffi.gc(C.bm_alloc(n), C.bm_free)
	C.bm_zero(ret, n)
	return ret
end

local ecode = {
	[tonumber(C.FHK_SOLVER_FAILED)] = "No solution exists",
	[tonumber(C.FHK_VAR_FAILED)]    = "Failed to resolve given variable",
	[tonumber(C.FHK_MODEL_FAILED)]  = "Model call failed",
	[tonumber(C.FHK_RECURSION)]     = "Solver called itself"
}

ffi.metatype("struct fhk_graph", { __index = {
	newvmask = function(self) return newbitmap(self.n_var) end,
	newmmask = function(self) return newbitmap(self.n_mod) end,
	init     = C.fhk_init,
	reset    = C.fhk_reset_mask,
	error    = function(self) return ecode[tonumber(self.last_error.err)] end
}})

--------------------------------------------------------------------------------
-- mapped graphs
-- the below functions assume the graph is mapped as in graph_map.c

local function solver_failed_m(G)
	local err = G.last_error
	local context = {"fhk: solver failed"}

	if err.var ~= nil then
		local name = C.fhkG_nameV(G, err.var.idx)
		if name ~= ffi.NULL then
			table.insert(context, string.format("\t* Caused by this variable: %s",ffi.string(name)))
		end
	end

	if err.model ~= nil then
		local name = C.fhkG_nameM(G, err.model.idx)
		if name ~= ffi.NULL then
			table.insert(context, string.format("\t* Caused by this model: %s", ffi.string(name)))
		end
	end

	if err.err == C.FHK_MODEL_FAILED then
		table.insert(context, string.format("Model crashed (%d) details below:",C.FHK_MODEL_FAILED))
		table.insert(context, model.error())
	else
		table.insert(context, string.format("\t* Reason: %s (%d)", G:error(), err.err))
	end

	error(table.concat(context, "\n"))
end

local graph_mt = { __index = {} }

local function root(G, fvars, fmodels)
	C.fhkG_hook_root(G)

	for name,fv in pairs(fvars) do
		C.fhkG_set_nameV(G, fv.idx, name)
	end

	for name,fm in pairs(fmodels) do
		C.fhkG_set_nameM(G, fm.idx, name)
	end
	 
	return setmetatable({
		G       = G,
		fvars   = fvars,
		fmodels = fmodels
	}, graph_mt)
end

function graph_mt.__index:subgraph(vmask, mmask, malloc, free)
	if not malloc then
		malloc, free = C.malloc, C.free
	end

	local size = C.fhk_subgraph_size(self.G, vmask, mmask)
	local H = ffi.cast("struct fhk_graph *", malloc(size))
	if free then ffi.gc(H, free) end
	C.fhk_copy_subgraph(H, self.G, vmask, mmask)
	C.fhkG_hook_solver(C.fhkG_root_graph(self.G), H)

	local fvars, fmodels = {}, {}

	for i=0, tonumber(H.n_var)-1 do
		fvars[ffi.string(C.fhkG_nameV(H, i))] = H.vars+i
	end

	for i=0, tonumber(H.n_mod)-1 do
		fmodels[ffi.string(C.fhkG_nameM(H, i))] = H.models+i
	end

	return setmetatable({
		G       = H,
		fvars   = fvars,
		fmodels = fmodels
	}, graph_mt)
end

function graph_mt.__index:reduce(names, init_v)
	if init_v then
		self.G:init(init_v)
	end

	local vmask = self.G:newvmask()
	local mmask = self.G:newmmask()
	local nv, ys = self:collect(names)

	if C.fhk_reduce(self.G, nv, ys, vmask, mmask) ~= C.FHK_OK then
		solver_failed_m(self.G)
	end

	return vmask, mmask
end

function graph_mt.__index:collect(names)
	local ret = ffi.new("struct fhk_var *[?]", #names)

	for i,name in ipairs(names) do
		ret[i-1] = self.fvars[name] or error(string.format("var '%s' not included in subgraph", name))
	end

	return #names, ret
end

function graph_mt.__index:markv(names, vmask, mark)
	vmask = vmask or self.G:newmask()
	mark = mark or 0xff

	for _,name in ipairs(names) do
		local fv = self.fvars[name]
		if fv then
			vmask[fv.idx] = mark
		end
	end

	return vmask
end

----------------------------------------

-- TODO: rename mapper -> hints?
local mapper_mt = { __index={} }

local function mapper()
	return setmetatable({
		types   = {},
		classes = {}
	}, mapper_mt)
end

function mapper_mt.__index:hint(def)
	for name,hint in pairs(def.hints) do
		if hint.type then self:typehint(name, hint.type) end
		if hint.class then self:classhint(name, def.classes[hint.class]) end
	end

	return self
end

function mapper_mt.__index:typehint(name, typ)
	if type(typ) == "number" then
		typ = typing.tvalue_from_desc(typing.promote(typ))
	elseif type(typ) == "string" then
		typ = typing.pvalues[typ]
	end
	
	if self.types[name] then
		if self.types[name] ~= typ then
			error(string.format("Conflicting type hints for variable '%s': %s and %s",
				name, self.types[name], typ))
		end

		return
	end

	self.types[name] = typ

	return self
end

function mapper_mt.__index:classhint(name, class)
	if self.classes[name] and self.classes[name] ~= class then
		error(string.format("Conflicting class hint for variable '%s': %s and %s",
			name, self.classes[name], class))
	end

	self.classes[name] = class

	return self
end

function mapper_mt.__index:infer_desc(name, typ)
	local pv = self.types[name] or (self.classes[name] and typing.pvalues.mask)
	local isreal = ffi.istype("float", typ.ctype) or ffi.istype("double", typ.ctype)

	if not pv then
		if typ.desc then return typ.desc end
		if ffi.istype("float", typ.ctype)  then return typing.tvalues.f32.desc end
		if ffi.istype("double", typ.ctype) then return typing.tvalues.f64.desc end
		if typing.is_integer(typ.ctype) then
			-- assume not mask since no mask hint given
			return typing.demote(typing.pvalues.id.desc, ffi.sizeof(typ.ctype))
		end

		-- not real, not integer, hope it's a pointer
		if ffi.sizeof(typ.ctype) == ffi.sizeof("void *") then return typing.pvalues.udata.desc end

		error(string.format("Can't infer desc for '%s' from type %s; hint needed",
			name, typ))
	end

	if typ.desc then
		if typing.promote(typ.desc) ~= pv.desc then
			error(string.format("Incompatible type for '%s': %s (hint: %s)",
				name, typ.name, pv.name))
		end

		return typ.desc
	end

	if pv.name == "f64" then
		if ffi.istype("float", typ.ctype)  then return typing.tvalues.f32.desc end
		if ffi.istype("double", typ.ctype) then return typing.tvalues.f64.desc end
		error(string.format("Incompatible type for '%s': %s (hint was real, can't cast)",
			name, typ))
	end

	if pv.name == "u" then
		-- there's no good way to test if it is a pointer so just believe
		if ffi.sizeof(typ.ctype) == ffi.sizeof("void *") then
			return pv.desc
		end
		error(string.format("Incompatible type for '%s': %s (hint was pointer, but wrong size)",
			name, typ))
	end

	if typing.is_integer(typ.ctype) then
		return typing.demote(pv.desc, ffi.sizeof(typ.ctype))
	end
	error(string.format("Incompatible type for '%s': %s (hint was %s, but not integer)",
		name, typ, pv.name))
end

function mapper_mt.__index:typeof(name)
	return self.types[name] or
		error(string.format("No type information for variable '%s', hint needed", name))
end

function mapper_mt.__index:classof(name)
	return self.classes[name] or
		error(string.format("No class information for variable '%s', hint needed", name))
end

-- number|string -> pvalue
function mapper_mt.__index:import(name, value)
	if type(value) == "string" then
		value = self:classof(name)[value] or
			error(string.format("Class of variable '%s' doesn't contain '%s", name, value))
		return ffi.new("pvalue", {u64=value})
	end

	return C.vimportd(tonumber(value), self:typeof(name).desc)
end

-- number|pvalue|tvalue -> number|string
function mapper_mt.__index:export(name, value, how)
	if how == "class" and self.classes[name] then
		-- it's either a pvalue or tvalue, the mask might be less than 64 bits but that
		-- doesn't matter, the rest are going to be zeros
		local cv = value
		if type(value) == "cdata" then
			cv = value.u64
		end

		local cls = self:classof(name)
		for name,v in pairs(cls) do
			if v == cv then
				return name
			end
		end

		-- if not found then just print it as a number
	end

	local typ = self:typeof(name)

	if type(value) == "number" then
		-- numeric representation of the pvalue|tvalue
		value = ffi.new("pvalue", {[typ.name]=value})
	end

	return C.vexportd(value, typ.desc)
end

----------------------------------------

local context_mt = { __index={} }

local function context()
	return setmetatable({
		_given  = {},
		_hooks  = {}
	}, context_mt)
end

function context_mt:__call(name)
	local found = self._given[name]

	for _,g in ipairs(self._given) do
		local map = g(name)
		if map then
			if found then
				error(string.format("Conflicting mappings for name '%s': %s and %s",
					name, found, map))
			end
			found = map
		end
	end

	return found
end

function context_mt.__index:given(...)
	for _,x in ipairs({...}) do
		if type(x) == "string" then
			self._given[x] = true
		else
			if type(x) == "table" and x.fhk_map then
				x = misc.delegate(x, x.fhk_map)
			end
			table.insert(self._given, x)
		end
	end

	return self
end

local function yield_subcontexts(ctx)
	coroutine.yield(ctx)

	for _,c in ipairs(ctx._given) do
		if getmetatable(c) == context_mt then
			yield_subcontexts(c)
		end
	end
end

function context_mt.__index:subcontexts()
	return coroutine.wrap(function() yield_subcontexts(self) end)
end

function context_mt.__index:hook(h)
	table.insert(self._hooks, h)
	return self
end

function context_mt.__index:callhook(name, ...)
	for c in self:subcontexts() do
		for _,h in ipairs(c._hooks) do
			if h[name] then
				h[name](h, ...)
			end
		end
	end
end

function context_mt.__index:over(wrap)
	if type(wrap) == "table" and wrap.fhk_over then
		wrap = misc.delegate(wrap, wrap.fhk_over)
	end

	self._wrap = wrap
	return self
end

function context_mt.__index:wrap()
	local found

	for c in self:subcontexts() do
		if c._wrap then
			if found and c._wrap ~= found then
				error(string.format("Context conflict: multiple wrappers defined: %s and %s",
					found, c._wrap))
			end
			found = c._wrap
		end
	end

	return found
end

----------------------------------------

local function reduce_subgraph(root, given, names)
	local init_v = root.G:newvmask()
	root:markv(given, init_v, ffi.new("fhk_vbmap", {given=1}).u8)
	root:markv(names, init_v, 0)
	return root:reduce(names, init_v)
end

local function create_solver_init_mask(graph, given, direct, names)
	local init_v = graph.G:newvmask()
	graph:markv(given, init_v, ffi.new("fhk_vbmap", {given=1}).u8)
	graph:markv(direct, init_v, ffi.new("fhk_vbmap", {given=1, has_value=1}).u8)
	graph:markv(names, init_v, 0)
	return init_v
end

local function create_solver_reset_masks(graph, const)
	local reset_v = graph.G:newvmask()
	local reset_m = graph.G:newmmask()
	graph:markv(const, reset_v, 0xff)
	C.bm_not(reset_v, graph.G.n_var) -- mark NON-constant
	C.fhk_compute_reset_mask(graph.G, reset_v, reset_m)
	return reset_v, reset_m
end

local function wrap_solver(solve, c_solver, G, callbacks)
	return function(self, ...)
		local r = solve(...)

		while r ~= C.FHK_OK do
			if band(r, C.FHKG_INTERRUPT_V) ~= 0 then
				r = C.fhkG_solver_resumeV(
					c_solver,
					callbacks[tonumber(band(r, C.FHKG_HANDLE_MASK))](self)
				)
			else
				solver_failed_m(G)
			end
		end
	end
end

local function bind_mappings(graph, given, solver, mapper)
	local const = {}

	for name,fv in pairs(graph.fvars) do
		if given[name] and given[name] ~= true then
			local mapping, cst = given[name](solver, mapper, name)
			C.fhkM_mapV(graph.G, fv.idx, mapping)
			if cst then table.insert(const, name) end
			mapper:typehint(name, C.fhkM_mapV_type(mapping))
		end
	end

	return const
end

local function graph_vptr(graph, mapper, name)
	local cp = ffi.typeof("$ *", mapper:typeof(name).ctype)
	return ffi.cast(cp, typing.memb_ptr("struct fhk_var", "value", graph.fvars[name]))
end

local function solver_mt(graph, mapper, solver, names, direct, solve)
	local vp = {}
	if solver:is_iter() then
		local binds = solver:binds()
		for i,name in ipairs(names) do
			vp[name] = ffi.cast(ffi.typeof("$**", mapper:typeof(name).ctype), binds+(i-1))
		end
	else
		for _,name in ipairs(names) do
			vp[name] = graph_vptr(graph, mapper, name)
		end
	end

	local dp = {}
	for _,name in ipairs(direct) do
		dp[name] = graph_vptr(graph, mapper, name)
	end

	return {
		__index = function(_, name) return vp[name][0] end,
		__newindex = function(_, name, value) dp[name][0] = value end,
		__call = solve
	}
end

local solverdef_mt = { __index={} }

 -- special key for accessing solver udata, because string keys are reserved for variable names
local __udata = {}

local function udata(x)
	return x[__udata]
end

local function solverdef(names, arena)
	return setmetatable({
		names     = names,
		context   = context(),
		_arena    = arena,
		[__udata] = {}
	}, solverdef_mt)
end

-- shortcuts
function solverdef_mt.__index:given(...) self.context:given(...) return self end
function solverdef_mt.__index:plan(...) self.context:plan(...) return self end
function solverdef_mt.__index:over(...) self.context:over(...) return self end
function solverdef_mt.__index:hook(...) self.context:hook(...) return self end

-- definition -> subgraph
function solverdef_mt.__index:to_subgraph(root)
	if self.graph then return end

	local given = {}
	local given_names, direct_names = {}, {}
	for name,_ in pairs(root.fvars) do
		given[name] = self.context(name)
		if given[name] then table.insert(given_names, name) end
		if given[name] == true then table.insert(direct_names, name) end
	end

	self.given = given
	self.given_names = given_names
	self.direct_names = direct_names

	local vmask, mmask = reduce_subgraph(root, self.given_names, self.names)
	self.graph = root:subgraph(vmask, mmask, self._arena and misc.delegate(self._arena, self._arena.malloc))
	self.context:callhook("subgraph", self.graph)
end

-- this is meant as a performance optimization for mappings to be able to allocate persistent
-- auxiliary structures (see eg. soa.lua), instead of spamming the luajit gc with thousands
-- of small cdata structs
-- TODO: init_v, reset_v, reset_m should also be allocated on the arena if given
-- subgraph should NOT be allocated on the arena as it should be discarded after solver generation
function solverdef_mt.__index:arena()
	if not self._arena then
		-- no pregiven arena, but we promised to the solver to persist it so it must be
		-- attached to prevent gc
		-- (if the arena is pregiven we don't anchor it, it should be anchored to the owner)
		local arena = alloc.arena()
		udata(self).arena___ = arena
		self._arena = arena
	end

	return self._arena
end

function solverdef_mt.__index:create(iter)
	local nv, ys = self.graph:collect(self.names)
	local init_v = create_solver_init_mask(self.graph, self.given_names, self.direct_names,
		self.names)
	
	-- anchor it to the solver to prevent it from being gc'd,
	-- since the only reference to it is in C from fhkG_solver
	udata(self).init_v___ = init_v

	-- ys doesn't need to be anchored, it's copied
	-- G doesn't need to be anchored, wrap_solver() will reference it
	
	-- solver doesn't need to be anchored because it's referenced from a closure,
	-- however, we still need the reference after the transformation
	-- to obtain a reference to the graph, so it's stored in udata

	if iter then
		iter = ffi.cast("struct fhkG_map_iter *", iter)
		udata(self).solver = C.fhkG_solver_create_iter(self.graph.G,nv,ys,init_v,iter,nil,nil)

		self.context:hook({mappings=function(_, _, const)
			local cst = {}
			for _,c in ipairs(const) do table.insert(cst, c) end
			-- treat directs as constants, ie. dont reset them
			for _,d in ipairs(self.direct_names) do table.insert(cst, d) end

			local reset_v, reset_m = create_solver_reset_masks(self.graph, cst)
			-- anchor to prevent gc
			udata(self).reset_v___ = reset_v
			udata(self).reset_m___ = reset_m
			C.fhkG_solver_set_reset(udata(self).solver, reset_v, reset_m)
		end})
	else
		udata(self).solver = C.fhkG_solver_create(self.graph.G, nv, ys, init_v)
	end

	return udata(self).solver
end

-- subgraph -> solver
-- Note: this will change the metatable
function solverdef_mt.__index:to_solver(mapper, callbacks)
	local wrap = self.context:wrap()
	local solve = wrap and wrap(self) or self:create()
	solve = wrap_solver(solve, udata(self).solver, self.graph.G, callbacks)

	-- this must be done after calling wrap(), the mappings may depend on information
	-- saved in wrap
	local const = bind_mappings(self.graph, self.given, self, mapper)
	self.context:callhook("mappings", self.graph, const)

	local mt = solver_mt(self.graph,mapper,udata(self).solver,self.names,self.direct_names,solve)

	self.names = nil
	self.context = nil
	self.given = nil
	self.given_names = nil
	self.direct_names = nil
	self.graph = nil
	self._arena = nil
	setmetatable(self, mt)
	-- it's now transformed to a solver
end

ffi.metatype("struct fhkG_solver", {
	__index = {
		graph   = C.fhkG_solver_graph,
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

----------------------------------------

local collect_mt = { __index={} }

local function collect(v, m)
	return setmetatable({
		vars   = v and {},
		models = m and {}
	}, collect_mt)
end

function collect_mt.__index:usevar(name)
	if not self.vars[name] then
		self.vars[name] = {}
	end
	return self.vars[name]
end

function collect_mt.__index:usemodel(name)
	self.models[name] = true
end

function collect_mt.__index:subgraph(graph)
	if self.vars then
		for name,fv in pairs(graph.fvars) do
			local v = self:usevar(name)

			if fv.n_mod == 0 then v.given = true end
			if fv.n_mod >  0 then v.computed = true end
			if fv.n_fwd == 0 then v.target = true end
		end
	end

	if self.models then
		for name,_ in pairs(graph.fmodels) do
			self:usemodel(name)
		end
	end
end

----------------------------------------

local plan_mt = { __index={} }

local function plan(def, arena)
	arena = arena or alloc.arena(2^20)
	local usemod = collect(false, true)

	return setmetatable({
		root      = root(build_graph(def, arena)),
		mapper    = mapper():hint(def),
		modeldef  = def.models,
		calibrate = calibrator(def.calibs),
		context   = context():hook(usemod),
		usemod    = usemod,
		solvers   = {},
		virtuals  = virtual.virtuals(),
		arena     = arena
	}, plan_mt)
end

function plan_mt.__index:solve(names)
	if self._prepared then
		error("Plan already created")
	end

	local solver = solverdef(names, self.arena):given(self.context)
	table.insert(self.solvers, solver)
	return solver
end

function plan_mt.__index:to_subgraphs()
	for _,s in ipairs(self.solvers) do
		if getmetatable(s) == solverdef_mt then
			s:to_subgraph(self.root)
		end
	end
end

function plan_mt.__index:to_solvers()
	self:to_subgraphs()
	for _,s in ipairs(self.solvers) do
		if getmetatable(s) == solverdef_mt then
			s:to_solver(self.mapper, self.virtuals.callbacks)
		end
	end
end

function plan_mt.__index:prepare()
	-- subgraphs must be selected to obtain the list of models that are actually used
	-- solvers don't necessarily need to be created, but type hints are given during
	-- solver creation so we make sure solvers are created
	self:to_solvers()

	-- TODO: in the future this can be replaced by lazy model init:
	-- call a virtual from C when model is first accessed
	
	local models = {}
	local conf = model.config()
	for name,_ in pairs(self.usemod.models) do
		local cal = self.calibrate(name)

		models[name] = create_model(
			self.modeldef[name],
			self.mapper,
			cal ~= nil,
			conf
		)

		if cal then
			cal(models[name])
		end
	end

	-- the downside to this method is that each model def needs to be copied to each subgraph,
	-- since the model is only resolved after subgraph creation
	for _,s in ipairs(self.solvers) do
		local G = udata(s).solver:graph()
		for i=0, tonumber(G.n_mod)-1 do
			-- it should be in the list, it's a bug if not
			local name = ffi.string(C.fhkG_nameM(G, i))
			C.fhkM_mapM(G, i, models[name] or assert(false))
		end

		-- after calling this function the plan is useless and can be discarded to save memory,
		-- so anchor the model list to solvers, since the models need to be alive
		udata(s).models___ = models
	end
	
	self._prepared = true
end

--------------------------------------------------------------------------------

local function inject(env, def)
	local arena = alloc.arena()
	local plan = plan(def, arena)

	env.m2.fhk = {
		masks   = def.classes,
		context = context,
		collect = collect,
		solve = function(...) return plan:solve({...}) end,
		virtuals = function() return plan.virtuals:vset() end,
		select_subgraphs = function() plan:to_subgraphs() end,
		type = function(name, hint) plan.mapper:typehint(name, hint) end,
		class = function(name, hint) plan.mapper:classhint(name, hint) end,

		-- the arena will contain the fhk structures so it must be kept alive after
		-- the plan is discarded, so it's anchored here
		arena___ = arena,

		-- root graph contains the root fhk graph and name references, so it must be kept alive
		-- TODO: copy the names to an arena, keep a reference to the struct fhk_graph
		-- and discard the root graph (this saves some memory and gc pressure)
		root___  = plan.root
	}

	-- this is to allow hooking before or after the prepare call
	env.sim:on("fhk:plan", function(plan)
		plan:prepare()
	end)

	env.sim:on("sim:compile", function()
		env.sim:event("fhk:plan", plan)

		-- plan can be discarded here to save memory
		plan = nil
	end)
end

--------------------------------------------------------------------------------

return {
	def               = gdef,
	def_env           = def_env,
	build_graph       = build_graph,
	create_model      = create_model,
	calibrate_model   = calibrate_model,
	root              = root,
	mapper            = mapper,
	udata             = udata,
	inject            = inject
}
