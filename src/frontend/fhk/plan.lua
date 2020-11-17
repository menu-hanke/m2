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
local mapping_mt = { __index={} }
local typing_mt = { __index={} }
local dsyms_mt = { __index={} }

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

-- included builtin: ... -> map [, is_set]
-- included user:    ... -> create_map [, is_set]
-- missing:          ... -> nil
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

local function subgraph_mapping(subgraph)
	return setmetatable({
		subgraph = subgraph,

		-- [idx|name] -> false            not included in the graph
		--            -> {name,group}     included
		--            -> + {typeid, create}    as given
		--            -> + {typeid, subset}    as root
		--                                (vars can be given, root, both or neither)
		vars     = {},

		-- [idx] -> {group, model, params, checks, returns}
		-- * params, checks, returns [idx] -> {target, map, is_set [, create]}
		models   = {}
	}, mapping_mt)
end

function mapping_mt.__index:var(name)
	if self.vars[name] ~= nil then
		return self.vars[name]
	end

	local group, typeid, create = self.subgraph:map_var(name)

	if not group then
		-- not included in graph either as given or computed
		assert(not (typeid or create))
		self.vars[name] = false
	else
		assert((typeid and create) or not (typeid or create))
		self.vars[name] = {
			name   = name,
			group  = group,
			typeid = typeid,
			create = create,
			given  = create ~= nil
		}
		table.insert(self.vars, self.vars[name])
	end

	return self.vars[name]
end

function mapping_mt.__index:map_edges(model, edges)
	local mapped = {}

	for _,e in ipairs(edges) do
		-- this may cause unneeded variables to be included in the supergraph, but it doesn't
		-- matter because they will be pruned later anyway
		local tv = self:var(e.target)
		if not tv then
			return
		end

		local map, is_set = self.subgraph:map_edge(model, e.target, e.subset)

		if not map then
			map, is_set = mapping.builtin_map_edge(mod, e.target, e.subset)
		end

		if not map then
			error(string.format("unmapped edge %s=>%s : %s", mod.name, e.target, e.subset))
		end

		table.insert(mapped, {
			target = tv,
			map    = type(map) == "function" and C.FHKM_USER or map,
			create = type(map) == "function" and map or nil,
			is_set = is_set
		})
	end

	return mapped
end

-- put given variables first for driver
function mapping_mt.__index:sort()
	table.sort(self.vars, function(a, b)
		if a.given ~= b.given then
			return a.given
		end
		return a.name < b.name
	end)
end

-- note: only includes models for which group and all edges are mapped
function mapping_mt.__index:include_models(models, create)
	for name, mod in pairs(models) do
		local group = self.subgraph:map_model(name)

		if group then
			local params = self:map_edges(mod, mod.params)
			local checks = params and self:map_edges(mod, mod.checks)
			local returns = checks and self:map_edges(mod, mod.returns)

			if returns then
				table.insert(self.models, {
					group   = group,
					model   = mod,
					params  = params,
					checks  = checks,
					returns = returns,
					create  = create
				})
			end
		end
	end
end

function mapping_mt.__index:include_roots(roots)
	for _,r in ipairs(roots) do
		local v = self:var(r.name)

		if not v then
			error(string.format("Root var '%s' is not mapped", r.name))
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
end

function subgraph_mt.__index:mapping(def, create_mod)
	local mp = subgraph_mapping(self)
	mp:include_models(def.models, create_mod)
	-- TODO: mp:include_models(virtuals, create_virtual_mod)
	mp:include_roots(self:roots())
	mp:sort()
	return mp.vars, mp.models
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
	return e.is_set and conv.toset(vty) or vty
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
			:intersect(conv.typemask(p.is_set and "set" or "single"))

		local typ = C.mt_autoconv(self:typeof_edge(p), tm.mask)

		if typ == C.MT_INVALID then
			error(string.format("Can't autoconvert %s -> %s (parameter '%s' of '%s)."
				.. "\n* param type -> %s"
				.. "\n* edge mask -> %s"
				.. "\n* arity -> `%s`",
				conv.nameof(self:typeof_edge(p)), tm, p.target.name, m.model.name,
				conv.typemask():intersect(m.model.impl:param_types(i)),
				link.astype,
				p.is_set and "set" or "single"))
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

local function build_subgraph(m_vars, m_models, types, static_alloc, dsyms)
	local scratch = alloc.arena()
	local D = ffi.gc(C.fhk_create_def(), C.fhk_destroy_def)

	-- step 1. build supergraph for fhk_reduce()-ing it into the subgraph.
	-- this is rebuilt for every subgraph because edge maps could be different.

	local sup_g = indexer()

	for _,v in ipairs(m_vars) do
		v.sup_idx = D:add_var(sup_g[v.group], 0)
	end

	for _,m in ipairs(m_models) do
		local idx = D:add_model(sup_g[m.group], m.model.k, m.model.c)
		m.sup_idx = idx -- for dsym

		-- all umap indices are 0 now, that's ok, they don't matter yet

		for _,p in ipairs(m.params) do
			D:add_param(idx, p.target.sup_idx, p.map)
		end

		for _,r in ipairs(m.returns) do
			D:add_return(idx, r.target.sup_idx, r.map)
		end

		for i,c in ipairs(m.checks) do
			local check = m.model.checks[i]
			-- unlike edge maps, model calls, var sizes, etc. the constraints need to actually
			-- exist for the reducer, so it must be allocated and created now.
			-- add_check() copies the constraint so it can be safely allocated in the scratch space.
			c.cst = scratch:new("fhk_cst")
			check.create_constraint(c.cst, types:typeof(c.target.name))
			c.cst.penalty = check.penalty
			D:add_check(idx, c.target.sup_idx, c.map, c.cst)
		end
	end

	-- step 2. reduce it into a subgraph

	local G = D:build(scratch:malloc(D:size()))

	-- this is done to have debug output in fhk_reduce().
	-- ok to copy it in scratch space, it lives only for the fhk_reduce() call.
	if dsyms then
		dsyms:copy_alloc(G, m_vars, m_models,
			function(e) return e.sup_idx, e.name or e.model.name end,
			misc.delegate(scratch, scratch.alloc)
		)
	end

	local r_flags = scratch:new("uint8_t", #m_vars)

	for i, v in ipairs(m_vars) do
		local flag = 0
		if v.given then flag = C.FHKR_GIVEN end
		if v.root then flag = flag + C.FHKR_ROOT end
		r_flags[i-1] = flag
	end

	local S, fxi = G:reduce(scratch, r_flags)
	if not S then
		error(string.format("Can't select subgraph: '%s' was not pruned", m_vars[fxi+1].name))
	end

	-- step 3. build the subgraph

	local sub_g = indexer()
	D:reset()

	for i, v in ipairs(m_vars) do
		if S:var(i-1) then
			v.sub_idx = D:add_var(sub_g[v.group], conv.sizeof(types:typeof(v.name)))
		end
	end

	for i, m in ipairs(m_models) do
		if S:model(i-1) then
			local idx = D:add_model(sub_g[m.group], m.model.k, m.model.c)
			m.sub_idx = idx -- for dsym

			-- TODO: for user maps: edge.create(???) -> idx, map |= idx
			
			for _,p in ipairs(m.params) do
				assert(p.map ~= C.FHKM_USER)
				D:add_param(idx, p.target.sub_idx, p.map)
			end

			for _,r in ipairs(m.returns) do
				assert(r.map ~= C.FHKM_USER)
				D:add_return(idx, r.target.sub_idx, r.map)
			end

			for _,c in ipairs(m.checks) do
				assert(c.map ~= C.FHKM_USER)
				D:add_check(idx, c.target.sub_idx, c.map, c.cst)
			end
		end
	end

	local G = D:build(static_alloc(D:size(), ffi.alignof("fhk_graph")))

	if dsyms then
		-- this must be copied with static_alloc() since it should outlive G
		dsyms:copy_alloc(G, m_vars, m_models,
			function(e) return e.sub_idx, e.name or e.model.name end,
			static_alloc
		)
	end

	return G, sub_g
end

local function compile_driver(G, m_vars, m_models, types, static_alloc, runtime_alloc)
	local gen = driver.gen()
	local sym_vars, sym_models = {}, {}

	-- umaps
	-- TODO: build subgraph should collect user maps into a g_maps table
	-- (edge.create() will return the umap index, each unique edge.create is run once,
	-- give it static_alloc and virtuals)

	-- given variables

	local n_given = 0
	for _,v in ipairs(m_vars) do
		if v.sub_idx then
			sym_vars[v.sub_idx] = v.name

			if v.given then
				n_given = n_given+1
			end
		end
	end

	local d_vars = ffi.cast("fhkD_given *",
		static_alloc(ffi.sizeof("fhkD_given")*n_given, ffi.alignof("fhkD_given")))
	
	for _,v in ipairs(m_vars) do
		if v.sub_idx and v.given then
			-- TODO also pass virtuals here
			v.create(d_vars+v.sub_idx, gen, static_alloc, runtime_alloc)
		end
	end
	
	-- models

	local d_models = ffi.cast("fhkD_model *",
		static_alloc(ffi.sizeof("fhkD_model")*G.nm, ffi.alignof("fhkD_model")))
	
	for _,m in ipairs(m_models) do
		if m.sub_idx then
			sym_models[m.sub_idx] = m.model.name

			-- TODO and also pass virtuals here
			m.create(d_models+m.sub_idx, m, types, gen, static_alloc, runtime_alloc)
		end
	end

	local D = ffi.cast("fhkD_driver *",
		static_alloc(ffi.sizeof("fhkD_driver"), ffi.alignof("fhkD_driver")))
	
	D.d_vars = d_vars
	D.d_models = d_models
	D.d_maps = nil -- TODO

	return gen:compile(D, { vars = sym_vars, models = sym_models })
end

local function compile_shapeinit(g_groups)
	local shapef = {}

	for g,i in pairs(g_groups) do
		shapef[i] = g:shape_func()
	end

	return driver.compile_shapeinit(shapef)
end

function subgraph_mt.__index:create_solvers(
		def,
		create_mod,
		static_alloc, runtime_alloc,
		dsyms,
		obtain, release)

	self.create_solvers = function() error("subgraph:create_solvers() called twice") end

	if #self._solvers == 0 then
		return
	end

	local m_vars, m_models = self:mapping(def, create_mod)
	local types = typing(m_vars, m_models)

	-- note: this writes sub_idx to m_vars/m_models included in subgraph
	local G, g_groups = build_subgraph(m_vars, m_models, types, static_alloc, dsyms)

	local drv = compile_driver(G, m_vars, m_models, types, static_alloc, runtime_alloc)
	local shapeinit = compile_shapeinit(g_groups)

	for _,s in ipairs(self._solvers) do
		for _,v in ipairs(s) do
			v.idx = m_vars[v.name].sub_idx or assert(false)
			v.group = g_groups[m_vars[v.name].group]
			v.ctype = v.ctype or conv.ctypeof(types:typeof(v.name))
		end

		s:bind(
			shapeinit,
			s:compile(G, static_alloc, runtime_alloc),
			drv,
			obtain, release
		)
	end
end

function solver_mt.__index:compile(G, static_alloc, runtime_alloc)
	local rq = ffi.cast("struct fhk_req *",
		static_alloc(#self * ffi.sizeof("struct fhk_req"),
			ffi.alignof("struct fhk_req"))
	)

	local fields, types, mangled, subsets = {}, {}, {}, {}

	for i,v in ipairs(self) do
		rq[i-1].idx = v.idx
		rq[i-1].buf = nil

		if type(v.subset) == "cdata" then
			rq[i-1].ss = v.subset
		else
			subsets[i] = v.subset
		end

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

	for i,v in ipairs(self) do
		if subsets[i] then
			solve:emitf("local subset%d = subsets[%d]", i-1, i)
		end
	end

	-- TODO: opt if needed: res could be taken as parameter or allocated statically
	-- in some situations (should be explicitly requested by user)
	
	-- another possible optimization: change the alloc code to something like
	--     local chunk = alloc( <precalculated size & align> )
	--     local res = ffi.cast(res_ctp, chunk)
	--     ...
	--     rq[i].buf = chunk + <precalc offset>
	--     ...

	solve:emitf([[
		local ffi = ffi
		local C = ffi.C
		local G, alloc, space, size = G, alloc, space, size
		local rq, res_ctp = rq, res_ctp

		return function(state, shape, arena)
			local res = ffi.cast(res_ctp, alloc(%d, %d))
	]], ffi.sizeof(res_ct), ffi.alignof(res_ct))

	for i,v in ipairs(self) do
		if v.subset then
			if subsets[i] then
				solve:emitf([[
					rq[%d].ss = state[subset%d]
					rq[%d].buf = alloc(size(rq[%d].ss) * %d, %d)
				]],
				i-1, i-1,
				i-1, i-1, ffi.sizeof(v.ctype), ffi.alignof(v.ctype))
			else
				solve:emitf([[
					rq[%d].buf = alloc(%d, %d)
				]],
				i-1, i-1,
				i-1, fhk_ct.ss_size(v.subset)*ffi.sizeof(v.ctype), ffi.alignof(v.ctype))
			end
			solve:emitf("res.%s = rq[%d].buf", mangled[i], i-1)
		else
			solve:emitf("rq[%d].ss = space(shape[%d])", i-1, v.group)
		end
	end

	-- optimization: use direct buffers for spaces.
	-- split in two loops to group the allocations and fhk calls
	for i,v in ipairs(self) do
		if not v.subset then
			solve:emitf("res.%s = alloc(shape[%d] * %d, %d)",
				mangled[i], v.group, ffi.sizeof(v.ctype), ffi.alignof(v.ctype))
		end
	end

	solve:emitf("local solver = C.fhk_create_solver(G, arena, %d, rq)", #self)
	solve:emit("C.fhkS_shape_table(solver, shape)")

	for i,v in ipairs(self) do
		if not v.subset then
			solve:emitf("C.fhkS_use_mem(solver, %d, res.%s)", v.idx, mangled[i])
		end
	end

	solve:emit([[
			return solver, res
		end
	]])

	return solve:compile({
		ffi     = ffi,
		rq      = rq,
		res_ctp = ffi.typeof("$*", res_ct),
		G       = G,
		alloc   = runtime_alloc,
		subsets = subsets,
		space   = fhk_ct.space,
		size    = fhk_ct.ss_size
	}, string.format("=(solve@%p)", self))()
end

function solver_mt.__index:bind(make_shape, make_solver, driver, obtain, release)
	if not self._f then
		error(string.format("Missing solver function: %s (did you forget to call create?)", self._f))
	end

	code.setupvalue(self._f, "_make_shape", make_shape)
	code.setupvalue(self._f, "_make_solver", make_solver)
	code.setupvalue(self._f, "_driver", driver)
	code.setupvalue(self._f, "_obtain", obtain)
	code.setupvalue(self._f, "_release", release)
end

local function dsyms_intern(alloc)
	return setmetatable({alloc=alloc, syms={}}, dsyms_mt)
end

function dsyms_mt.__index:sym(s)
	local sym = self.syms[s]
	if not sym then
		sym = self.alloc(#s+1, 1)
		ffi.copy(sym, s)
		self.syms[s] = sym
	end
	return sym
end

function dsyms_mt.__index:copy_syms(dest, es, infof)
	for _,e in ipairs(es) do
		local idx, name = infof(e)
		if idx then
			dest[idx] = self:sym(name)
		end
	end
end

function dsyms_mt.__index:copy_alloc(G, vars, models, infof, alloc)
	alloc = alloc or self.alloc

	local ds_v = ffi.cast("const char **", alloc(ffi.sizeof("void *")*G.nv, ffi.alignof("void *")))
	local ds_m = ffi.cast("const char **", alloc(ffi.sizeof("void *")*G.nm, ffi.alignof("void *")))

	self:copy_syms(ds_v, vars, infof)
	self:copy_syms(ds_m, models, infof)

	G:set_dsym(ds_v, ds_m)
end

local function arena_pool()
	local pool = {}

	return
		-- obtain
		function()
			if pool[#pool] then
				local ret = pool[#pool]
				pool[#pool] = nil
				return ret
			end

			-- the default arena size doesn't really matter too much so just take enough
			return ffi.gc(C.arena_create(2^20), C.arena_destroy)
		end,

		-- release
		function(arena)
			pool[#pool+1] = arena
		end
end

local function create_model_func()
	-- scratch buffer for signature as seen by graph (max mt_sig size is 2*256 + 2 = 514.)
	local g_sig = ffi.gc(ffi.cast("struct mt_sig *", C.malloc(514)), C.free)

	-- scratch buffer for signature as seen by model (autoconverted)
	local m_sig = ffi.gc(ffi.cast("struct mt_sig *", C.malloc(514)), C.free)

	return function(dm, mm, types, _, static_alloc)
		local conv, npc, nc = nil, 0, 0
		types:sigof(g_sig, mm)
		types:autoconvsig(m_sig, mm)

		if g_sig ~= m_sig then
			conv, npc, nc = driver.mcall_conv(g_sig, m_sig, static_alloc)
		end

		-- TODO: cache mm.impl:create(m_sig)
		driver.mcall(dm, mm.model.impl:create(m_sig), conv, npc, nc)
	end
end

---- public api ----------------------------------------

function plan_mt.__index:finalize(def, opt)
	self.finalize = function() error("plan:finalize() called twice") end
	local dsyms = C.fhk_is_debug() and dsyms_intern(opt.static_alloc)
	local create_mod = create_model_func()
	local obtain, release = arena_pool()

	for _,s in ipairs(self.subgraphs) do
		s:create_solvers(
			def,
			-- TODO: virtuals table (virtual handles will be shared even for models, even if
			-- the models aren't)
			create_mod,
			opt.static_alloc,
			opt.runtime_alloc,
			dsyms,
			obtain, release
		)
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
--         * create(dv, gen, static_alloc, runtime_alloc)
--                                             create mapping on dv.
--                                             it's safe to store aux data in gen[my_object]
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

		-- if you want a custom subset.
		-- cdata -> always use this constant subset
		-- string -> read this key from state
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
		error("create() called twice on this solver")
	end

	-- load used here to make luajit always compile a new root trace
	-- (see eg. https://github.com/luafun/luafun/pull/33)
	self._f = load([[
		local _make_shape, _make_solver, _driver, _obtain, _release

		return function(state)
			local arena = _obtain()
			local shape = _make_shape(state, arena)
			local solver, res = _make_solver(state, shape, arena)
			local err = _driver(state, solver, arena)
			_release(arena)
			if err then error(err) end
			return res
		end
	]], nil, nil, {
		obtain = pool_obtain,
		release = pool_release,
		error = error
	})()

	return self._f
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
