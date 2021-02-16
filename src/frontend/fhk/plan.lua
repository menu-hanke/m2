local fhk_ct = require "fhk.ctypes"
local driver = require "fhk.driver"
local mapping = require "fhk.mapping"
local sym = require "fhk.sym"
local conv = require "model.conv"
local code = require "code"
local alloc = require "alloc"
local misc = require "misc"
local ffi = require "ffi"
local C = ffi.C

local plan_mt = { __index={} }
local compiler_mt = { __index={} }
local subgraph_mt = { __index={} }
local subgraph_compiler_mt = { __index={} }
local solver_mt = { __index={} }
local mapping_mt = { __index={} }
local solver_mapping_mt = { __index={} }
local typing_mt = { __index={} }

-- given:     name -> group, type, create
-- computed:  name -> group
-- missing:   name -> nil
function subgraph_mt.__index:map_var(name)
	local group, typ, create

	for _,i in ipairs(self._includes) do
		local g,t,c = i:map_var(name)
		if g then
			group, typ, create = group
				and error(string.format("mapping conflict: '%s' is mapped by %s and %s", name, g, group))
				or g, t, c
		end
	end

	for _,g in ipairs(self._groups) do
		local t,c = g:map_var(name)
		if t then
			group, typ, create = group
				and error(string.format("mapping conflict: '%s' is mapped by %s and %s", name, g, group))
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
				and error(string.format("mapping conflict: '%s' is mapped by %s and %s", name, g, group))
				or g
		end
	end

	for _,g in ipairs(self._groups) do
		if g:map_model(name) then
			group = group
				and error(string.format("mapping conflict: '%s' is mapped by %s and %s", name, g, group))
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
				and error(string.format("mapping conflict: multiple maps for this edge: %s->%s",
					model.name, vname))
				or o,s,c
		end
	end

	for _,e in ipairs(self._edges) do
		local o,s,c = e(model, vname, subset)
		if o then
			op, set, create = op
				and error(string.format("mapping conflict: multiple maps for this edge: %s->%s",
					model.name, vname))
				or o,s,c
		end
	end

	return op, set, create
end

function subgraph_mt.__index:roots()
	local roots = {}
	for _,s in ipairs(self._solvers) do
		for _,v in ipairs(s) do
			table.insert(roots, v)
		end
	end

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
			map, is_set = mapping.builtin_map_edge(model, e.target, e.subset)
		end

		if not map then
			error(string.format("unmapped edge %s=>%s : %s", model.name, e.target, e.subset))
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
function mapping_mt.__index:define_model(name, model)
	local group = self.subgraph:map_model(name)

	if group then
		local params = self:map_edges(model, model.params)
		local checks = params and self:map_edges(model, model.checks)
		local returns = checks and self:map_edges(model, model.returns)

		if returns then
			table.insert(self.models, {
				group   = group,
				model   = model,
				params  = params,
				checks  = checks,
				returns = returns
			})
		end
	end
end

function mapping_mt.__index:add_root(r)
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

local function typing(mapping)
	local typ = setmetatable({
		vars    = mapping.vars,
		models  = mapping.models,
		_typeof = {}
	}, typing_mt)

	for _,var in ipairs(mapping.vars) do
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
			error(string.format("can't determine unique return type for '%s'."
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
		error(string.format("conflicting types for '%s'", name))
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

-- aux structure to help emit solvers (solver here meaning a lua function that calls
-- into a driver that actually calls into fhk).
--
-- the hierarchy goes something like this:
--     compiler: all subgraphs here will share:
--         * debug symbols
--         * models (actual model callers)
--         * virtuals
--         * memory pools
--
--         -> subgraph: all solvers of this subgraph will share:
--             * subgraph, ie. the fhk_graph structure (obviously)
--             * driver+mappings
--             * shape table
--
local function compiler(def, opt)
	return setmetatable({
		def             = def,
		trace           = opt.trace,
		static_alloc    = opt.static_alloc,
		runtime_alloc   = opt.runtime_alloc
	}, compiler_mt)
end

function compiler_mt.__index:sym(name)
	if not self.syms then
		self.syms = {}
	end

	local sym = self.syms[name]
	if not sym then
		sym = self.static_alloc(#name+1, 1)
		ffi.copy(sym, name)
		self.syms[name] = sym
	end

	return sym
end

function compiler_mt.__index:pool()
	if self._pool then
		return self._pool.obtain, self._pool.release
	end

	local pool = {}

	self._pool = {
		obtain = function()
			local arena = pool[#pool]
			if arena then
				pool[#pool] = nil
				return arena
			end

			return alloc.arena(2^20)
		end,

		release = function(arena)
			arena:reset()
			pool[#pool+1] = arena
		end
	}

	return self:pool()
end

function compiler_mt.__index:map_syms(G, mapping, index, alloc)
	local vsym = ffi.cast("const char **", alloc(ffi.sizeof("void *")*G.nv, ffi.alignof("void *")))
	local msym = ffi.cast("const char **", alloc(ffi.sizeof("void *")*G.nm, ffi.alignof("void *")))

	for _,v in ipairs(mapping.vars) do
		local idx = index(v)
		if idx then
			vsym[idx] = self:sym(v.name)
		end
	end

	for _,m in ipairs(mapping.models) do
		local idx = index(m)
		if idx then
			msym[idx] = self:sym(m.model.name)
		end
	end

	G:set_dsym(vsym, msym)
end

function subgraph_compiler_mt.__index:mapping()
	if self._mapping then
		return self._mapping, self._types
	end

	local mapping = subgraph_mapping(self.subgraph)

	-- this includes virtuals (injected in def)
	for name, mod in pairs(self.compiler.def.models) do
		mapping:define_model(name, mod)
	end

	for _,var in pairs(self.subgraph:roots()) do
		mapping:add_root(var)
	end

	mapping:sort()
	self._mapping = mapping
	self._types = typing(mapping)
	return mapping, self._types
end

function subgraph_compiler_mt.__index:reduced_subgraph()
	if self._G then
		return self._G, self._groups
	end

	local mapping, types = self:mapping()
	local scratch = alloc.arena()
	local D = ffi.gc(C.fhk_create_def(), C.fhk_destroy_def)

	-- step 1. build supergraph for fhk_reduce()-ing it into the subgraph.
	-- this is rebuilt for every subgraph because edge maps could be different.

	local sup_g = indexer()

	for _,v in ipairs(mapping.vars) do
		v.sup_idx = D:add_var(sup_g[v.group], 0)
	end

	for _,m in ipairs(mapping.models) do
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
	if C.fhk_is_debug() then
		self.compiler:map_syms(G, mapping, function(e) return e.sup_idx end,
			misc.delegate(scratch, scratch.alloc))
	end

	local r_flags = scratch:new("uint8_t", #mapping.vars)

	for i, v in ipairs(mapping.vars) do
		local flag = 0
		if v.given then flag = C.FHKR_GIVEN end
		if v.root then flag = flag + C.FHKR_ROOT end
		r_flags[i-1] = flag
	end

	local S, fxi = G:reduce(scratch, r_flags)
	if not S then
		error(string.format("inconsistent subgraph: '%s' was not pruned", mapping.vars[fxi+1].name))
	end

	-- step 3. build the subgraph

	local sub_g = indexer()
	D:reset()

	for i, v in ipairs(mapping.vars) do
		if S:var(i-1) then
			v.sub_idx = D:add_var(sub_g[v.group], conv.sizeof(types:typeof(v.name)))
		end
	end

	for i, m in ipairs(mapping.models) do
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

	local G = D:build(self.compiler.static_alloc(D:size(), ffi.alignof("fhk_graph")))

	if C.fhk_is_debug() then
		-- this must be copied with static_alloc() since it should outlive G
		self.compiler:map_syms(G, mapping, function(e) return e.sub_idx end,
			self.compiler.static_alloc)
	end

	self._G = G
	self._groups = sub_g
	return G, sub_g
end

function subgraph_compiler_mt.__index:symbols()
	if self._symbols then
		return self._symbols
	end

	local mapping = self:mapping()
	local symbols = sym.symbols()

	for _,v in ipairs(mapping.vars) do
		if v.sub_idx then
			symbols.var[v.sub_idx] = v.name
		end
	end

	for _,m in ipairs(mapping.models) do
		if m.sub_idx then
			symbols.model[m.sub_idx] = m.model.name
		end
	end

	self._symbols = symbols
	return symbols
end

function subgraph_compiler_mt.__index:trace()
	if self._trace ~= nil or not self.compiler.trace then
		return self._trace or nil, self._trace_install
	end

	local trace, install = self.compiler.trace(self)
	self._trace = trace or false
	self._trace_install = install
	return trace, install
end

function subgraph_compiler_mt.__index:driver()
	if self._driver then
		return self._driver
	end

	local mapping = self:mapping()
	local builder = driver.builder()

	for _,v in ipairs(mapping.vars) do
		if v.sub_idx and v.given then
			builder:given(v.sub_idx, self:create_var(v))
		end
	end

	for _,m in ipairs(mapping.models) do
		if m.sub_idx then
			builder:model(m.sub_idx, self:create_model(m))
		end
	end

	local driver = builder:compile {
		alloc   = self.compiler.static_alloc,
		trace   = self:trace(),
		symbols = self:symbols()
	}

	local _, release = self.compiler:pool()
	local caller = code.new():emit([[
		local driver, release, error = driver, release, error

		return function(state, solver, arena)
			local err = driver(state, solver, arena)
			release(arena)
			if err then error(err) end
		end
	]]):compile({
		driver  = driver,
		release = release,
		error   = error
	}, string.format("=(subgraphdriver@%p)", driver))()

	self._driver = caller
	return caller
end

function subgraph_compiler_mt.__index:create_var(v)
	local _, install = self:trace()

	return function(dv, umem)
		v.create(dv, umem)

		if install then
			install("var", v, dv, umem)
		end
	end
end

function subgraph_compiler_mt.__index:create_model(m)
	-- TODO: if model.impl is virtual, then we create a virtual model here.
	---- C model creation below.
	
	-- TODO: the buffer sizes really shouldn't be hardcoded.
	
	-- TODO: values returned by impl:create() should be cached somewhere, probably this
	-- (compiler/plan level) is the most natural place.
	-- caching in the model impl could allow for more sharing, but would require implementing
	-- caching separately for each caller (and implementing basic caching @ compiler level
	-- doesn't prevent optimized caching in the caller)
	
	local _, install = self:trace()
	local _, types = self:mapping()
	
	return function(dm, umem)
		-- scratch buffer for signature as seen by graph (max mt_sig size is 2*256 + 2 = 514.)
		local g_sig = ffi.cast("struct mt_sig *", C.malloc(514))

		-- scratch buffer for signature as seen by model (autoconverted)
		local m_sig = ffi.cast("struct mt_sig *", C.malloc(514))

		types:sigof(g_sig, m)
		types:autoconvsig(m_sig, m)

		local impl = m.model.impl:create(m_sig)
		dm:set_mcall(impl.call, impl, driver.conv(g_sig, m_sig, self.compiler.static_alloc))

		if install then
			install("model", m, dm, umem)
		end

		C.free(g_sig)
		C.free(m_sig)
	end
end

function subgraph_compiler_mt.__index:solver_mapping(solver)
	local mapping, types = self:mapping()
	local _, groups = self:reduced_subgraph()

	local def = {}

	for _,v in ipairs(solver) do
		table.insert(def, {
			-- field name in result ctype
			name            = v.alias or v.name:gsub("[^%w]", "_"):gsub("^([^%a_])", "_%1"),

			-- result ctype. this must be the same as graph ctype
			ctype           = v.ctype or conv.ctypeof(types:typeof(v.name)),

			-- subgraph variable index
			idx             = mapping.vars[v.name].sub_idx or assert(false),

			-- group index
			group           = groups[mapping.vars[v.name].group],

			-- pregiven subset (may be nil, see comment in solve())
			subset          = v.subset,

			-- `subset` is a constant subset?
			fixed_subset    = type(v.subset) == "cdata",

			-- `subset` is a key to lookup the set from `state`?
			computed_subset = v.subset and type(v.subset) ~= "cdata",

			-- do not use the solver buffer directly (the given variable may be given using
			-- fhkS_give_all, which won't work with fhkS_use_mem because they tell fhk to
			-- use different direct buffers).
			-- note: `given` doesn't necessarily imply fhkS_give_all, it would be possible to
			-- look at the mapper and check if it's going to use it.
			-- requesting given variables is not very useful outside debugging though, so
			-- it's not worth optimizing
			direct_buffer   = not (v.subset or mapping.vars[v.name].given)
		})
	end

	return setmetatable(def, solver_mapping_mt)
end

function solver_mapping_mt.__index:result_ctype()
	local fields, ctypes = {}, {}

	for _,v in ipairs(self) do
		table.insert(fields, string.format("$ *%s;", v.name))
		table.insert(ctypes, v.ctype)
	end

	return ffi.typeof(string.format("struct { %s }", table.concat(fields, "")), unpack(ctypes))
end

function subgraph_compiler_mt.__index:compile_solver_init(solver)
	local def = self:solver_mapping(solver)

	local req = ffi.cast("struct fhk_req *", self.compiler.static_alloc(
		#def*ffi.sizeof("struct fhk_req"), ffi.alignof("struct fhk_req")
	))

	for i,v in ipairs(def) do
		req[i-1].idx = v.idx
		req[i-1].buf = nil
		if v.fixed_subset then
			req[i-1].ss = v.subset
		end
	end

	local res_ct = def:result_ctype()

	local out = code.new()

	for i,v in ipairs(def) do
		if v.computed_subset then
			out:emitf("local __subset_%d = def[%d].subset", i, i)
		end
	end

	out:emitf([[
		local ffi = require "ffi"
		local C, cast = ffi.C, ffi.cast
		local fhk_ct = require "fhk.ctypes"
		local space, size = fhk_ct.space, fhk_ct.ss_size
		local G, req = G, req
		local res_ctp = res_ctp

		return function(state, shape, arena)
			local res = cast(res_ctp, alloc(%d, %d))
	]], ffi.sizeof(res_ct), ffi.alignof(res_ct))

	-- TODO: allocate everything in a single `alloc` call so that luajit can actually optimize
	-- the `req` initialization`

	for i,v in ipairs(def) do
		out:emit("do")
		
		if v.fixed_subset then
			out:emitf([[
				local buf = alloc(%d, %d)
				req[%d].buf = buf
			]],
			fhk_ct.ss_size(v.subset)*ffi.sizeof(v.ctype), ffi.alignof(v.ctype),
			i-1)
		elseif v.computed_subset then
			out:emitf([[
				local buf = alloc(size(state[__subset_%d])*%d, %d)
				req[%d].ss = state[__subset_%d]
				req[%d].buf = buf
			]],
			i, ffi.sizeof(v.ctype), ffi.alignof(v.ctype),
			i-1, i,
			i-1)
		else
			-- fast path for space
			-- TODO: compute the space/size only once per group
			out:emitf([[
				local buf = alloc(shape[%d]*%d, %d)
				req[%d].ss = space(shape[%d])
				req[%d].buf = buf
			]],
			v.group, ffi.sizeof(v.ctype), ffi.alignof(v.ctype),
			i-1, v.group,
			i-1)
		end

		out:emitf([[
			res.%s = buf
			end
		]], v.name)
	end

	out:emitf([[
		local solver = C.fhk_create_solver(G, arena, %d, req)
		C.fhkS_shape_table(solver, shape)
	]], #def)

	-- direct buffer optimization, fhk will copy others.
	for i,v in ipairs(def) do
		if v.direct_buffer then
			out:emitf("C.fhkS_use_mem(solver, %d, res.%s)", v.idx, v.name)
		end
	end

	out:emit([[
		return solver, res
		end
	]])

	return out:compile({
		require = require,
		req     = req,
		G       = self:reduced_subgraph(),
		res_ctp = ffi.typeof("$*", res_ct),
		alloc   = self.compiler.runtime_alloc,
		def     = def
	}, string.format("=(initsolver@%p)", def))()
end

function subgraph_compiler_mt.__index:init()
	if self._init then
		return self._init
	end

	local _, groups = self:reduced_subgraph()
	local out = code.new()

	local shapef = {}
	for group,idx in pairs(groups) do
		shapef[idx] = group:shape_func()
	end

	for i,_ in pairs(shapef) do
		out:emitf("local __shape_%d = shapef[%d]", i, i)
	end

	out:emitf([[
		local ffi = require "ffi" 
		local C, cast = ffi.C, ffi.cast
		local fhk_idxp = ffi.typeof "fhk_idx *"
		local obtain = obtain

		return function(state)
			local arena = obtain()
			local shape = cast(fhk_idxp, C.arena_alloc(arena, %d, %d))
	]], #shapef*ffi.sizeof("fhk_idx"), ffi.alignof("fhk_idx"))

	for i,_ in pairs(shapef) do
		out:emitf("shape[%d] = __shape_%d(state)", i, i)
	end

	out:emit([[
			return shape, arena
		end
	]])

	self._init = out:compile({
		require = require,
		shapef  = shapef,
		obtain  = self.compiler:pool()
	}, string.format("=(subgraphinit@%p)", groups))()

	return self._init
end

function compiler_mt.__index:compile_subgraph(subgraph)
	return setmetatable({
		compiler = self,
		subgraph = subgraph
	}, subgraph_compiler_mt)
end

local function solver_template()
	-- load is used to compile a new root trace
	-- see: https://github.com/luafun/luafun/pull/33
	return load([[
		local _init, _create, _driver

		return function(state)
			local shape, arena = _init(state)
			local solver, result = _create(state, shape, arena)
			_driver(state, solver, arena)
			return result
		end
	]])()
end

local function bind_solver(template, init, create, driver)
	code.setupvalue(template, "_init", init)
	code.setupvalue(template, "_create", create)
	code.setupvalue(template, "_driver", driver)
end

function subgraph_compiler_mt.__index:bind(template, solver)
	bind_solver(
		template,
		self:init(),
		self:compile_solver_init(solver),
		self:driver()
	)
end

function compiler_mt.__index:compile_plan(plan)
	for _,subgraph in ipairs(plan.subgraphs) do
		local subcompiler = self:compile_subgraph(subgraph)
		for _,solver in ipairs(subgraph._solvers) do
			subcompiler:bind(plan.solvers[solver], solver)
		end
	end
end

---- public api ----------------------------------------

local function plan()
	return setmetatable({
		subgraphs = {},
		solvers   = {}
	}, plan_mt)
end

function plan_mt.__index:compile(...)
	compiler(...):compile_plan(self)
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
--         * create(dv, umem)                  create mapping on dv.
--                                             it's safe to store aux data in umem[my_object]
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

function subgraph_mt.__index:solver()
	local solver = setmetatable({}, solver_mt)
	table.insert(self._solvers, solver)
	return solver
end

function plan_mt.__index:add_solver(solver)
	local template = solver_template()
	self.solvers[solver] = template
	return template
end

function plan_mt.__index:solver(subgraph, ...)
	return self:add_solver(subgraph:solver():solve(...))
end

function solver_mt.__index:solve(...)
	for _,x in ipairs({...}) do
		if type(x) == "string" then
			self:add(x)
		else
			for _,name in ipairs(x) do
				self:add(name, x)
			end
		end
	end

	return self
end

function solver_mt.__index:add(name, opt)
	opt = opt or {}
	local ctype = opt.ctype and ffi.typeof(opt.ctype)

	-- TODO: opt.single - take a single result, inline it in the struct

	table.insert(self, {
		name   = name,
		alias  = opt.alias,

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
	compiler = compiler,
	create   = plan
}
