local compile = require "fhk.compile"
local graph = require "fhk.graph"
local ctypes = require "fhk.ctypes"
local infer = require "fhk.infer"
local ffi = require "ffi"
local C = ffi.C

ffi.cdef [[
	float nextafterf(float from, float to);
	double nextafter(double from, double to);
]]

local function materialize_edge(model, var, edge, view)
	if not var then return end
	local map, scalar = view:edge(model, var, edge)
	if not map then return end
	return graph.edge(edge.target, map, { scalar = scalar })
end

local function materialize_types(nodeset)
	for _,v in pairs(nodeset.vars) do
		if v.ctype then
			v.ts = infer.typeset(v.ctype)
		end
	end

	local isret = {}
	for _,m in pairs(nodeset.models) do
		for _,e in ipairs(m.returns) do
			local x = nodeset.vars[e.target]
			isret[x] = true
			if e.ts then
				x.ts = infer.intersect(x.ts, e.ts)
			end
		end
	end

	local notype = {}
	for name,v in pairs(nodeset.vars) do
		if v.ts then
			if #v.ts ~= 1 then
				error(string.format("no unique type for '%s' (choices: %s)", name, infer.tostring(v.ts)))
			end
			v.ctype = infer.ctfromid(v.ts[1])
		else
			-- it's ok to include this in the graph, it will either be pruned or cause an error
			-- during model creation.
			notype[name] = true
			assert(v.ctype == nil)
		end
	end

	if not next(notype) then
		return
	end

	-- this is a bit hacky. we now have vars that don't have a ctype, which means they will
	-- never have a value. this means (1) they are uncomputable, (2) their shadows can
	-- never be materialized.
	-- it's perfecly fine to have variables that can never be touched, so we don't error
	-- out here. however, we must now remove the unmaterializable shadows.
	
	local delete = {}
	for name,s in pairs(nodeset.shadows) do
		if notype[s.var] then
			delete[name] = true
		end
	end

	-- no shadows to replace, ie. all shadows refer to typed variables
	if not next(delete) then
		return
	end

	for name,_ in pairs(delete) do
		nodeset.shadows[name] = nil
	end

	for _,m in pairs(nodeset.models) do
		local i = 1
		while i <= #m.shadows do
			local e = m.shadows[i]
			if delete[e.target] then
				m.k = m.k + m.c*e.penalty
				table.remove(m.shadows, i)
			else
				i = i+1
			end
		end
	end
end

local shadowmat = {
	["&"] = {
		[tonumber(ffi.typeof "uint8_t")] = function(x) return C.FHKC_U8_MASK64, ctypes.shvalue{u64=x} end
	},
	[">="] = {
		[tonumber(ffi.typeof "double")] = function(x) return C.FHKC_GEF64, ctypes.shvalue{f64=x} end,
		[tonumber(ffi.typeof "float")] = function(x) return C.FHKC_GEF32, ctypes.shvalue{f32=x} end
	},
	[">"] = {
		[tonumber(ffi.typeof "double")] = function(x) return C.FHKC_GEF64, ctypes.shvalue{f64=C.nextafter(x, math.huge)} end,
		[tonumber(ffi.typeof "float")] = function(x) return C.FHKC_GEF32, ctypes.shvalue{f32=C.nextafterf(x, math.huge)} end
	},
	["<="] = {
		[tonumber(ffi.typeof "double")] = function(x) return C.FHKC_LEF64, ctypes.shvalue{f64=x} end,
		[tonumber(ffi.typeof "float")] = function(x) return C.FHKC_LEF32, ctypes.shvalue{f32=x} end
	},
	["<"] = {
		[tonumber(ffi.typeof "double")] = function(x) return C.FHKC_LEF64, ctypes.shvalue{f64=C.nextafter(x, -math.huge)} end,
		[tonumber(ffi.typeof "float")] = function(x) return C.FHKC_LEF32, ctypes.shvalue{f32=C.nextafterf(x, -math.huge)} end
	}
}

local function materialize_shadow(shadow, ctype)
	if not shadowmat[shadow.guard] then
		error(string.format("invalid guard: %s", shadow.guard))
	end

	local f = shadowmat[shadow.guard][tonumber(ctype)]
	if not f then
		error(string.format("no materialization for guard %s with ctype %s (%s -> %s)",
			shadow.guard, ctype, shadow.name, shadow.var))
	end

	local guard, arg = f(shadow.arg)
	return graph.shadow(shadow.name, shadow.var, guard, arg)
end

local function materialize(nodeset, view)
	local ns = graph.nodeset()

	for name,var in pairs(nodeset.vars) do
		local ctype, create = view:var(var)
		ns.vars[name] = graph.var(name, {
			ctype  = ctype,
			create = create
		})
	end

	for name,mod in pairs(nodeset.models) do
		local sigset, create = view:model(mod)
		if not sigset then goto skip end

		local m = graph.model(name, {
			create = create,
			k      = mod.k,
			c      = mod.c,
			cmin   = mod.cmin
		})

		for i,edge in ipairs(mod.params) do 
			local e = materialize_edge(mod, ns.vars[edge.target], edge, view)
			if not e then goto skip end
			e.ts = sigset.params and sigset.params[i]
			table.insert(m.params, e)
		end

		for i,edge in ipairs(mod.returns) do
			local e = materialize_edge(mod, ns.vars[edge.target], edge, view)
			if not e then goto skip end
			e.ts = sigset.returns and sigset.returns[i]
			table.insert(m.returns, e)
		end

		for _,edge in ipairs(mod.shadows) do
			local shadow = nodeset.shadows[edge.target]
			local e = materialize_edge(mod, ns.vars[shadow.var], edge, view)
			if not e then goto skip end
			e.penalty = edge.penalty
			table.insert(m.shadows, e)
		end

		ns.models[name] = m

		::skip::
	end

	-- type materialization deletes typeless shadows, so copy them here first
	for name,shadow in pairs(nodeset.shadows) do
		ns.shadows[name] = shadow
	end

	materialize_types(ns)

	for name,shadow in pairs(ns.shadows) do
		ns.shadows[name] = materialize_shadow(shadow, ns.vars[shadow.var].ctype)
	end

	return ns
end

local function iter_order(nodes)
	if #nodes > 0 then
		return ipairs(nodes)
	else
		return pairs(nodes)
	end
end

local function copydsym(mapping, alloc)
	local nx = mapping.nodes[0] and #mapping.nodes+1 or 0

	local syms, intern = {}, alloc and {}
	local i = nx-1
	while mapping.nodes[i] do
		local sym = mapping.nodes[i].name

		if alloc then
			if not intern[sym] then
				intern[sym] = alloc(#sym+1, 1)
				ffi.copy(intern[sym], sym)
			end
			syms[i] = intern[sym]
		else
			syms[i] = ffi.string(sym)
		end

		i = i-1
	end
	
	local nm = -i-1
	local dsym

	if alloc then
		dsym = nm + ffi.cast("const char **", alloc(ffi.sizeof("void *")*(nm+nx), ffi.alignof("void *")))
	else
		dsym = ffi.new("const char *[?]", nm+nx)

		-- very big XXX here: this needs to be anchored somewhere to prevent gc,
		-- this may not be the best place but it does the job.
		mapping[dsym] = true

		-- this one doesn't need to be anchored
		dsym = nm + dsym
	end

	for i=-nm, nx-1 do
		dsym[i] = syms[i]
	end

	return dsym
end

local function map_group(mapping, group, gnum)
	if not mapping.groups[group] then
		mapping.groups[group] = gnum
		mapping.groups[gnum] = group
		gnum = gnum+1
	end

	return gnum
end

local function map_ufunc(mapping, ufunc, inum, knum)
	if not mapping.umaps[ufunc] then
		local idx
		if graph.isconst(ufunc.flags) then
			idx, knum = knum, knum+1
		else
			idx, inum = inum-1, inum-1
		end

		mapping.umaps[ufunc] = idx
		mapping.umaps[idx] = ufunc
	end

	return inum, knum
end

local function edgemap(mapping, map)
	if type(map) == "number" then
		return map
	end

	return ctypes.map_user(mapping.umaps[map.map], mapping.umaps[map.inverse])
end

-- nodeset must be materialized.
-- order is a hack to enable building a graph with given variables first.
local function build(nodeset, order, alloc)
	local mapping = {
		groups = {},
		umaps  = {},
		nodes  = {}
	}

	local gnum, inum, knum = 0, 0, 0

	for _,node in pairs(nodeset.vars) do
		gnum = map_group(mapping, graph.groupof(node.name), gnum)
	end

	for _,node in pairs(nodeset.models) do
		gnum = map_group(mapping, graph.groupof(node.name), gnum)

		for _,es in ipairs({node.params, node.returns, node.shadows}) do
			for _,e in ipairs(es) do
				if e.map and type(e.map) ~= "number" then
					inum, knum = map_ufunc(mapping, e.map.map, inum, knum)
					inum, knum = map_ufunc(mapping, e.map.inverse, inum, knum)
				end
			end
		end
	end

	local objs = {}
	local D = ffi.gc(C.fhk_create_def(), C.fhk_destroy_def)

	for _,v in iter_order(order and order.vars or nodeset.vars) do
		objs[v] = D:add_var(mapping.groups[graph.groupof(v.name)],
			v.ctype and ffi.sizeof(v.ctype) or 0, v.cdiff)
	end

	for _,s in iter_order(order and order.shadows or nodeset.shadows) do
		objs[s] = D:add_shadow(objs[nodeset.vars[s.var]], s.guard, s.arg)
	end

	for _,m in iter_order(order and order.models or nodeset.models) do
		local obj = D:add_model(mapping.groups[graph.groupof(m.name)], m.k, m.c, m.cmin or m.k)
		objs[m] = obj

		for _,e in ipairs(m.params) do
			D:add_param(obj, objs[nodeset.vars[e.target]], edgemap(mapping, e.map))
		end

		for _,e in ipairs(m.returns) do
			D:add_return(obj, objs[nodeset.vars[e.target]], edgemap(mapping, e.map))
		end

		for _,e in ipairs(m.shadows) do
			D:add_check(obj, objs[nodeset.shadows[e.target]], edgemap(mapping, e.map), e.penalty)
		end
	end

	for node,obj in pairs(objs) do
		local idx = D:idx(obj)
		mapping.nodes[idx] = node
		mapping.nodes[node] = idx
	end

	local G
	local dsym = C.fhk_is_debug() and copydsym(mapping, alloc)

	if alloc then
		G = D:build(alloc and alloc(D:size(), ffi.alignof("fhk_graph")))
	else
		G = ffi.gc(D:build(), dsym and function(G)
			C.fhk_destroy_graph(G)
			-- this keeps mapping alive, so it won't be collected before G.
			-- some reference to the syms needs to be kept alive because we alloced
			-- them via ffi, we choose to keep mapping alive.
			mapping = nil
		end or C.fhk_destroy_graph)
	end

	if dsym then
		C.fhk_set_dsym(G, dsym)
	end

	return G, mapping
end

local lazysyms_mt = {
	__index = function(self, idx)
		return self.mapping.nodes[idx].name
	end
}

local function _prune(nodeset, retain, mapping, P)
	local flags = P:flags()

	for _,name in ipairs(retain) do
		local var = nodeset.vars[name] or error(string.format("retained variable not in graph: %s", name))
		local idx = mapping.nodes[var]
		flags[idx] = bit.bor(flags[idx], C.FHKF_SELECT)
	end

	for _,v in pairs(nodeset.vars) do
		local idx = mapping.nodes[v]

		if v.create then
			flags[idx] = bit.bor(flags[idx], C.FHKF_GIVEN)
		end

		-- typeless variables can never be touched, so we explicitly ask them to be removed
		if not v.ctype then
			flags[idx] = bit.bor(flags[idx], C.FHKF_SKIP)
		end
	end

	local err = P:prune()
	if err ~= 0 then
		error(ctypes.errstr(err, setmetatable({mapping=mapping}, lazysyms_mt)))
	end

	local bounds = P:bounds()
	local ns = graph.nodeset()

	for name,v in pairs(nodeset.vars) do
		if bit.band(flags[mapping.nodes[v]], C.FHKF_SELECT) ~= 0 then
			local b = bounds[mapping.nodes[v]]
			ns.vars[name] = graph.var(name, {
				ctype  = v.ctype,
				create = v.create,
				cdiff  = b[1] - b[0]
			})
		end
	end

	for name,m in pairs(nodeset.models) do
		if bit.band(flags[mapping.nodes[m]], C.FHKF_SELECT) ~= 0 then
			ns.models[name] = graph.model(name, {
				create  = m.create,
				params  = m.params,
				returns = m.returns,
				shadows = m.shadows,
				k       = m.k,
				c       = m.c,
				cmin    = bounds[mapping.nodes[m]][0]
			})

			-- TODO: the pruner should really just set flags for shadows as well..
			for _,s in ipairs(m.shadows) do
				ns.shadows[s.target] = nodeset.shadows[s.target]
			end
		end
	end

	return ns
end

local function prune(nodeset, retain)
	local G, mapping = build(nodeset)
	local P = C.fhk_create_prune(G)
	local ok, x = pcall(_prune, nodeset, retain, mapping, P)

	-- this can't be done with an ffi.gc(): G's finalizer might run before P's does,
	-- which causes a use-after-free bug, so we have to destroy P manually.
	-- see: https://www.freelists.org/post/luajit/pinning-objects-in-ffigc-finalizers
	C.fhk_destroy_prune(P)

	if not ok then
		error(x)
	else
		return x
	end
end

local function flatten(dest, x)
	if type(x) == "table" then
		for _,y in ipairs(x) do
			flatten(dest, y)
		end
	else
		table.insert(dest, x)
	end
	return dest
end

local function shape(mapping, view)
	local shapef = {}
	if mapping.groups[0] then
		for i=0, #mapping.groups do
			local funs = view:shape(mapping.groups[i]) or
				error(string.format("no shape function for group: %s", mapping.groups[i]))
			shapef[i] = compile.shapefunc(flatten({}, funs))
		end
	end
	return shapef
end

-- this is not the same thing as dsyms: dsyms are fhk internal c strings only used when
-- fhk is compiled in debug mode. this functions returns an index->name mapping to use
-- in human readable messages.
local function symbols(mapping)
	local syms = {}
	local i = mapping.nodes[0] and #mapping.nodes or -1
	while mapping.nodes[i] do
		syms[i] = mapping.nodes[i].name
		i = i-1
	end
	return syms
end

return {
	materialize = materialize,
	build       = build,
	prune       = prune,
	shape       = shape,
	symbols     = symbols
}
