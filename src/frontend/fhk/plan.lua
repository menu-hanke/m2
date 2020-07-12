local fhk_ct = require "fhk.ctypes"
local driver = require "fhk.driver"
local mapping = require "fhk.mapping"
local conv = require "model.conv"
local code = require "code"
local alloc = require "alloc"
local misc = require "misc"
local ffi = require "ffi"
local C = ffi.C

local plan_mt = { __index={} }
local subgraph_mt = { __index={} }
local solver_mt = { __index={} }
local typing_mt = { __index={} }

local function plan()
	return setmetatable({
		subgraphs = {}
	}, plan_mt)
end

-- given:     name -> group, type, create
-- computed:  name -> group
-- missing:   name -> nil
function subgraph_mt.__index:map_var(name)
	local group, typ, create

	for _,i in ipairs(self._includes) do
		local g,t,c = i:map_var(name)
		if g then
			group, typ, create = group
				and error(string.format("Mapping conflict: '%s' is mapped by %s and %s", name, g, group))
				or g, t, c
		end
	end

	for _,g in ipairs(self._groups) do
		local t,c = g:map_var(name)
		if t then
			group, typ, create = group
				and error(string.format("Mapping conflict: '%s' is mapped by %s and %s", name, g, group))
				or g, t ~= true and t or nil, c
		end
	end

	return group, typ, create
end

-- included: name -> group
-- missing:  name -> nil
function subgraph_mt.__index:map_model(name)
	local group

	for _,i in ipairs(self._includes) do
		local g = i:map_model(name)
		if g then
			group = group
				and error(string.format("Mapping conflict: '%s' is mapped by %s and %s", name, g, group))
				or g
		end
	end

	for _,g in ipairs(self._groups) do
		if g:map_model(name) then
			group = group
				and error(string.format("Mapping conflict: '%s' is mapped by %s and %s", name, g, group))
				or g
		end
	end

	return group
end

-- included: ... -> map type [, set [, create]]
-- missing:  ... -> nil
function subgraph_mt.__index:map_edge(model, vname, subset)
	local op, set, create

	for _,i in ipairs(self._includes) do
		local o,s,c = i:map_edge(model, vname, subset)
		if o then
			op, set, create = op
				and error(string.format("Mapping conflict: multiple maps for this edge: %s->%s",
					model.name, vname))
				or o,s,c
		end
	end

	for _,e in ipairs(self._edges) do
		local o,s,c = e(model, vname, subset)
		if o then
			op, set, create = op
				and error(string.format("Mapping conflict: multiple maps for this edge: %s->%s",
					model.name, vname))
				or o,s,c
		end
	end

	return op, set, create
end

function subgraph_mt.__index:roots()
	if self._roots then
		return self._roots
	end

	local roots = {}
	for _,s in ipairs(self._solvers) do
		for _,v in ipairs(s) do
			table.insert(roots, v)
		end
	end

	self._roots = roots
	return roots
end

-- return   vars [idx|name] -> false            not included in the graph
--                          -> {name,group}     included
--                          -> + {typeid, create}    as given
--                          -> + {typeid, subset}    as root
--                                              (vars can be given, root, both or neither)
--
--             models [idx] -> {group, model, params, checks, returns}
--             - params,
--             - checks,
--             - returns [idx] -> {target, set, op [, arg][, create]}
function subgraph_mt.__index:mapping(def)
	local vars = setmetatable({}, {
		__index = function(vars, name)
			local group, typeid, create = self:map_var(name)

			if not group then
				-- not included in graph either as given or computed
				assert(not (typeid or create))
				vars[name] = false
			else
				assert((typeid and create) or not (typeid or create))
				vars[name] = {
					name   = name,
					group  = group,
					typeid = typeid,
					create = create,
					given  = create ~= nil
				}
				table.insert(vars, vars[name])
			end

			return vars[name]
		end
	})

	local function map_edges(mod, es)
		local mapped = {}

		for _,e in ipairs(es) do
			local tv = vars[e.target]
			if not tv then
				return
			end

			local op, set, x = self:map_edge(mod, e.target, e.subset)

			if not op then
				op, set, x = mapping.builtin_map_edge(mod, e.target, e.subset)
			end

			if not op then
				error(string.format("unmapped edge %s=>%s : %s", mod.name, e.target, e.subset))
			end

			table.insert(mapped, {
				target = tv,
				op     = op,
				set    = set,  -- bool
				arg    = ffi.istype("fhk_arg", x) and x or nil,        -- both of these may be nil
				create = (not ffi.istype("fhk_arg", x)) and x or nil   -- eg. if op is IDENT
			})
		end

		return mapped
	end

	local models = {}
	for name, mod in pairs(def.models) do
		local group = self:map_model(name)

		if group then
			local params = map_edges(mod, mod.params)
			local checks = params and map_edges(mod, mod.checks)
			local returns = checks and map_edges(mod, mod.returns)

			if returns then
				table.insert(models, {
					group   = group,
					model   = mod,
					params  = params,
					checks  = checks,
					returns = returns
				})
			end
		end

	end

	for _,r in ipairs(self:roots()) do
		local v = vars[r.name]

		if not v then
			error(string.format("Root var '%s' is not included in subgraph", r.name))
		end

		if v.typeid then
			if not r.tm:has(v.typeid) then
				error(string.format("Type conflict: you mapped '%s' as %s but solve it as %s",
					r.name, v.typeid, r.tm))
			end
		end

		v.tm = r.tm
		v.root = true
	end

	return vars, models
end

-- models, vars : returned by subgraph:mapping()
local function typing(vars, models)
	local typ = setmetatable({
		vars    = vars,
		models  = models,
		_typeof = {}
	}, typing_mt)

	for _,var in ipairs(vars) do
		if var then
			typ._typeof[var.name] = var.typeid -- may be nil
		end
	end

	typ:link_returns()

	return typ
end

function typing_mt.__index:link_returns()
	local retlinks = {}

	for _,mod in ipairs(self.models) do
		for i,r in ipairs(mod.returns) do
			local name = r.target.name
			if not retlinks[name] then retlinks[name] = {} end
			table.insert(retlinks[name], {
				impl    = mod.model.impl,
				index   = i,
				astype  = mod.model.returns[i].astype
			})
		end
	end

	self.retlinks = retlinks
end

function typing_mt.__index:typeof(name)
	if self._typeof[name] then
		return self._typeof[name]
	end

	local links = self.retlinks[name] or error(string.format("No model for '%s'", name))

	-- roots have a predefined mask
	local mask = self.vars[name].tm or conv.typemask()

	for _,link in ipairs(links) do
		-- we don't care here if the model returns a set or single value, we just care about
		-- the type
		local mm = conv.typemask("single")
			:intersect(link.impl:return_types(link.index))
			:intersect(link.astype)

		if not mm:isuniq() then
			error(string.format("Can't determine unique return type for '%s'."
				.. "\n* return types -> %s"
				.. "\n* edge mask -> %s"
				.. "\n* possibilites -> %s",
				name,
				conv.typemask(link.impl:return_types(link.index)),
				link.astype,
				mm
			))
		end

		mask = mask:intersect(mm)
	end

	local ty = mask:uniq()
	if not ty then
		error(string.format("Conflicting types for '%s'", name))
	end

	self._typeof[name] = ty
	return ty
end

function typing_mt.__index:typeof_edge(e)
	local vty = self:typeof(e.target.name)
	return e.set and conv.toset(vty) or vty
end

function typing_mt.__index:sigof(sig, m)
	sig.np = #m.params
	sig.nr = #m.returns

	for i,p in ipairs(m.params) do
		sig.typ[i-1] = self:typeof_edge(p)
	end

	for i,r in ipairs(m.returns) do
		sig.typ[sig.np+i-1] = self:typeof_edge(r)
	end

	return sig
end

function typing_mt.__index:autoconvsig(sig, m)
	sig.np = #m.params
	sig.nr = #m.returns

	for i,p in ipairs(m.params) do
		local link = m.model.params[i]
		local tm = conv.typemask():intersect(m.model.impl:param_types(i))
			:intersect(link.astype)
			:intersect(conv.typemask(p.set and "set" or "single"))

		local typ = C.mt_autoconv(self:typeof_edge(p), tm.mask)

		if typ == C.MT_INVALID then
			error(string.format("Can't autoconvert %s -> %s (parameter '%s' of '%s)."
				.. "\n* param type -> %s"
				.. "\n* edge mask -> %s"
				.. "\n* arity -> `%s`",
				conv.nameof(self:typeof_edge(p)), tm, p.target.name, m.model.name,
				conv.typemask():intersect(m.model.impl:param_types(i)),
				link.astype,
				p.set and "set" or "single"))
		end

		sig.typ[i-1] = typ
	end

	for i,r in ipairs(m.returns) do
		-- implementation of `typeof` quarantees this is uniquely defined and acceptable
		sig.typ[sig.np+i-1] = self:typeof_edge(r)
	end

	return sig
end

local function indexer()
	local ng = 0
	return setmetatable({}, {
		__index = function(self, k)
			assert(type(k) ~= "number")
			self[k] = ng
			ng = ng + 1
			return self[k]
		end
	})
end

local function copyds(ds, es, idxof, dsyms)
	for _,e in ipairs(es) do
		local idx = idxof(e)
		if idx then
			-- e.name for vars, e.model.name for models
			ds[idx] = dsyms[e.name or e.model.name]
		end
	end
end

local function copy_dsyms(G, vars, models, idxof, alloc, dsyms)
	local ds_v = ffi.cast("const char **", alloc(ffi.sizeof("void *")*G.nv, ffi.alignof("void *")))
	local ds_m = ffi.cast("const char **", alloc(ffi.sizeof("void *")*G.nm, ffi.alignof("void *")))

	copyds(ds_v, vars, idxof, dsyms)
	copyds(ds_m, models, idxof, dsyms)

	G:set_dsym(ds_v, ds_m)
end

function subgraph_mt.__index:create(def, create_mod, static_alloc, runtime_alloc, dsyms)
	self.create = function() error("subgraph:create() called twice") end

	-- the plan is as follows:
	-- (1) create a big graph, G, from the definition, but don't allocate any mappings yet
	--      * note: we can't use a shared supergraph (like old fhk did) even though the graph
	--              structure is the same, since we may have different edge maps in different
	--              graphs. (could use a cache if the edge maps match, but it's probably not worth
	--              the effort.)
	-- (2) run fhk_reduce on G
	-- (3) create the graph again, but only the subgraph H this time. allocate and create all
	--     mappings now.
	-- (4) compile solvers

	local m_vars, m_models = self:mapping(def)
	local types = typing(m_vars, m_models)

	local scratch = alloc.arena()
	local D = ffi.gc(C.fhk_create_def(), C.fhk_destroy_def)

	---- (1) supergraph --------------------

	local sup_g = indexer()

	for _,v in ipairs(m_vars) do
		v.sup_idx = D:add_var(sup_g[v.group], 0)
	end

	for _,m in ipairs(m_models) do
		local idx = D:add_model(sup_g[m.group], m.model.k, m.model.c)
		m.sup_idx = idx -- for dsym
		
		-- `arg` may be nil, that's ok

		for _,p in ipairs(m.params) do
			D:add_param(idx, p.target.sup_idx, p.op, p.arg)
		end

		for _,r in ipairs(m.returns) do
			D:add_return(idx, r.target.sup_idx, r.op, r.arg)
		end

		for i,c in ipairs(m.checks) do
			local check = m.model.checks[i]
			local op, arg = check.constraint(types:typeof(c.target.name))
			c.cop = op
			c.carg = arg
			c.penalty = check.penalty
			D:add_check(idx, c.target.sup_idx, c.op, c.arg, c.cop, c.carg, check.penalty)
		end
	end

	---- (2) subgraph selection --------------------

	local G = D:build(scratch:malloc(D:size()))

	if dsyms then
		copy_dsyms(G, m_vars, m_models, function(e) return e.sup_idx end,
			misc.delegate(scratch, scratch.alloc), dsyms)
	end

	local r_flags = scratch:new("uint8_t", #m_vars)

	for i, v in ipairs(m_vars) do
		local flag = 0
		if v.given then flag = C.FHK_GIVEN end
		if v.root then flag = flag + C.FHK_ROOT end
		r_flags[i-1] = flag
	end

	local S, fxi = G:reduce(scratch, r_flags)
	if not S then
		error(string.format("Can't select subgraph: '%s' was not pruned", m_vars[fxi+1].name))
	end

	---- (3) subgraph+driver --------------------

	local gen = driver.gen()
	local sub_g = indexer()
	D:reset()

	for i, v in ipairs(m_vars) do
		if S.r_vars[i-1] ~= C.FHK_SKIP then
			local udata = v.create and v.create(gen, static_alloc) or fhk_ct.ZERO_ARG
			v.sub_idx = D:add_var(sub_g[v.group], conv.sizeof(types:typeof(v.name)), udata)
		end
	end

	-- scratch buffer for signature as seen by graph (max mt_sig size is 2*256 + 2 = 514.)
	local g_sig = ffi.cast("struct mt_sig *", scratch:alloc(514, 1))

	-- scratch buffer for signature as seen by model (autoconverted)
	local m_sig = ffi.cast("struct mt_sig *", scratch:alloc(514, 1))

	for i, m in ipairs(m_models) do
		if S.r_models[i-1] ~= C.FHK_SKIP then
			types:sigof(g_sig, m)
			types:autoconvsig(m_sig, m)

			local gscopy, mscopy

			-- need to convert
			if g_sig ~= m_sig then
				local nalloc = (g_sig.np+g_sig.nr) * ffi.sizeof("mt_type")
				gscopy = static_alloc(nalloc, ffi.alignof("mt_type"))
				mscopy = static_alloc(nalloc, ffi.alignof("mt_type"))
				ffi.copy(gscopy, g_sig.typ, nalloc)
				ffi.copy(mscopy, m_sig.typ, nalloc)
			end

			local mp = create_mod(m.model, m_sig)
			local udata = driver.mcall(static_alloc, mp, gscopy, mscopy)

			local idx = D:add_model(sub_g[m.group], m.model.k, m.model.c, udata)
			m.sub_idx = idx -- for dsym

			-- TODO: create edge maps here too
			for _,p in ipairs(m.params) do
				D:add_param(idx, p.target.sub_idx, p.op, p.create and p.create() or p.arg)
			end

			for _,r in ipairs(m.returns) do
				D:add_return(idx, r.target.sub_idx, r.op, r.create and r.create() or r.arg)
			end

			for _,c in ipairs(m.checks) do
				D:add_check(idx, c.target.sub_idx, c.op, c.arg, c.cop, c.carg, c.penalty)
			end
		end
	end

	local G = D:build(static_alloc(D:size(), ffi.alignof("fhk_graph")))
	local drv = gen:compile()

	if dsyms then
		copy_dsyms(G, m_vars, m_models, function(e) return e.sub_idx end, static_alloc, dsyms)
	end

	---- (4) solvers --------------------

	local st = driver.shapetablegen()

	for g,i in pairs(sub_g) do
		st:shape(i, g:shape_func())
	end

	local makest = st:compile()

	for _,s in ipairs(self._solvers) do
		for i,v in ipairs(s) do
			v.idx = m_vars[v.name].sub_idx or assert(false)
			v.group = sub_g[m_vars[v.name].group]
			v.ctype = v.ctype or conv.ctypeof(types:typeof(v.name))
		end

		if not s._set_shapetable then
			error(string.format("This solver isn't prepared -> %s. did you forget to call create()?",
				s))
		end

		s._set_shapetable(makest)
		s._set_solver(s:compile(G, runtime_alloc, static_alloc))
		s._set_driver(drv)
	end
end

function solver_mt.__index:compile(G, static_alloc, runtime_alloc)
	local rq = ffi.cast("struct fhk_req *",
		static_alloc(#self * ffi.sizeof("struct fhk_req"),
			ffi.alignof("struct fhk_req"))
	)

	local fields, types, mangled = {}, {}, {}

	for i,v in ipairs(self) do
		rq[i-1].idx = v.idx
		rq[i-1].buf = nil

		-- need a valid C identifier for the result struct, so force this to be a valid C identifier
		-- by making non-alnums underscores and prepending an underscore if it starts with a number.
		-- eg. 7tree#h becomes _7tree_h.
		-- if we get conflicts, oh well, could append more underscores but better to just let it error.
		local name = v.name:gsub("[^%w]", "_"):gsub("^([^%a_])", "_%1")
		mangled[i] = name
		fields[i] = string.format("$ *%s;", name)
		types[i] = v.ctype
	end

	local res_ct = ffi.typeof(string.format("struct { %s }", table.concat(fields, "")), unpack(types))

	local solve = code.new()

	solve:emit([[
		local ffi = ffi
		local C = ffi.C
		local rq = rq

		return function(state, shape, arena)
			local res = arena:new(res_ct)
			local num, ss
	]])

	for i,v in ipairs(self) do
		if not v.map then
			-- special case: if no map is specified, use space by default.
			solve:emitf([[
				rq[%d].ss = space(shape[%d])
			]], i-1, v.group)
		else
			solve:emitf([[
				num, ss = ss%d()
				rq[%d].ss = ss
				rq[%d].buf = alloc(num * %d, %d)
				res.%s = rq[%d].buf
			]], i-1, i-1, i-1, ffi.sizeof(v.ctype), ffi.alignof(v.ctype), mangled[i], i-1)
		end
	end

	solve:emitf("local solver = C.fhk_create_solver(G, arena, %d, rq)", #self)

	-- optimization: use direct buffers for spaces
	-- in two loops to group the allocations and fhk calls

	for i,v in ipairs(self) do
		if not v.map then
			solve:emitf("res.%s = alloc(shape[%d] * %d, %d)",
				mangled[i], v.group, ffi.sizeof(v.ctype), ffi.alignof(v.ctype))
		end
	end

	for i,v in ipairs(self) do
		if not v.map then
			solve:emitf("C.fhkS_use_mem(solver, %d, res.%s)", v.idx, mangled[i])
		end
	end

	solve:emit([[
			return solver, res
		end
	]])

	return solve:compile({
		ffi    = ffi,
		rq     = rq,
		res_ct = res_ct,
		G      = G,
		alloc  = runtime_alloc,
		space  = fhk_ct.space
	}, string.format("=(solve@%p)", self))()
end

local function alloc_dsyms(def, alloc)
	return setmetatable({}, {
		__index = function(self, name)
			self[name] = alloc(#name+1, 1)
			ffi.copy(self[name], name)
			return self[name]
		end
	})
end

---- public api ----------------------------------------

function plan_mt.__index:finalize(def, opt)
	self.create = function() error("plan:finalize() called twice") end
	local dsyms = C.fhk_is_debug() and alloc_dsyms(def, opt.static_alloc)

	for _,s in ipairs(self.subgraphs) do
		if #s._solvers > 0 then
			s:create(
				def,
				-- TODO: this should probably be cached etc.
				function(model, sig) return model.impl:create(sig) end,
				opt.static_alloc,
				opt.runtime_alloc,
				dsyms
			)
		end
	end
end

local function subgraph(...)
	return setmetatable({
		_includes = {...},
		_groups   = {},
		_edges    = {},
		_solvers  = {}
	}, subgraph_mt)
end

function plan_mt.__index:subgraph(...)
	local sg = subgraph(...)
	table.insert(self.subgraphs, sg)
	return sg
end

function subgraph_mt.__index:edge(edge)
	table.insert(self._edges, edge)
	return self
end

-- groups callbacks:
--
--     group:map_var(name)  ->  nil            group doesn't map `name`
--                          ->  true           group maps `name` as computed
--                          ->  type, create   group maps `name` as given
--
--         * create(subgraph, arena) -> udata  create mapping info for given variable.
--                                             the arena will outlive the graph, so you can use it
--                                             for any allocations. the subgraph will be disposed
--                                             after its solvers have been created so you can
--                                             safely store auxiliary data in subgraph[my_object]
--
--    group:map_model(name) ->  nil            group doesn't map `name`
--                          ->  true           group maps `name` (ie. the model belongs in the group)
--
--    group:shape_func(gen) ->  sf             create the function that returns the group shape
--        * sf(state) -> shape                 return shape given state
function subgraph_mt.__index:given(group)
	table.insert(self._groups, group)
	return self
end

function subgraph_mt.__index:include(graph)
	table.insert(self._includes, graph)
	return self
end

function subgraph_mt.__index:solve(...)
	if self._graph then
		error("Common subgraph has already been selected; can't define a new solver")
	end

	local solver = setmetatable({}, solver_mt)
	table.insert(self._solvers, solver)

	return solver:solve(...)
end

-- solve(var, {...})
-- solve({var1, var2, ..., varN}, {...})  -- options apply to all vars
function solver_mt.__index:solve(var, opt)
	opt = opt or {}

	if type(var) == "table" then
		for _,v in ipairs(var) do
			self:solve(v, opt)
		end
		return self
	end

	local ctype = opt.ctype and ffi.typeof(opt.ctype)

	-- TODO: opt.single - take a single result, inline it in the struct

	table.insert(self, {
		name   = var,
		alias  = opt.as,

		-- function returning `fhk_subset`, or `nil` to solve over the whole space
		subset = opt.subset,

		-- both `typ` and `ctype` are optional. if not given, the type will be inferred by model
		-- returns. you can use them to assert the wanted type instead of silently getting
		-- unexpected results.
		tm     = conv.typemask(opt.typ):intersect(conv.typemask(ctype)),
		
		-- this is needed in addition to `tm` if handling pointers, since fhk just has a `pointer`
		-- type, but it doesn't know what it points to. if ctype is set then its used for casting
		-- the result. if not, the type is inferred from `tm` (this works for primitives, but
		-- all your pointers will be void *).
		ctype  = ctype
	})

	return self
end

function solver_mt.__index:create()
	if self._f then
		error("create_solver() called twice on this solver")
	end

	-- TODO: generoi vasta myöhemmin, nyt 3 muuttuvaa upvaluea

	-- * load used here to make luajit always compile a new root trace
	--   (see eg. https://github.com/luafun/luafun/pull/33)
	-- * `ffi.gc` used here instead of manually destroying the arena so that it is gced even
	--   if an error occurs. (currently this always allocates a new arena for simplicity.
	--   if this affects performance, it could get the arena from a pool etc).
	local f, set_shapetable, set_solver, set_driver = load([[
		local ffi = require "ffi"
		local C = ffi.C
		local makest, makesolver, driver

		return function(state)
			local arena = ffi.gc(C.arena_create(8000), C.arena_destroy)
			local shape = makest(state, arena)
			local solver, res = makesolver(state, shape, arena)
			C.fhkS_shape_table(solver, shape)
			driver(state, solver, arena)
			return res
		end,
		function(f) makest = f end,
		function(f) makesolver = f end,
		function(f) driver = f end
	]])()

	self._f = f
	self._set_shapetable = set_shapetable
	self._set_solver = set_solver
	self._set_driver = set_driver

	return f
end

function solver_mt:__tostring()
	local buf = {}
	for _,v in ipairs(self) do
		table.insert(buf, string.format("%s : %s %s", v.name, v.subset, v.tm))
	end
	return string.format("solver{%s}", table.concat(buf, ", "))
end

--------------------------------------------------------------------------------

return {
	create = plan
}
