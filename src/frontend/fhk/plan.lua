local compile = require "fhk.compile"
local driver = require "fhk.driver"
local transform = require "fhk.transform"
local graph = require "fhk.graph"
local alloc = require "alloc"

local function arenapool()
	local pool = {}

	local function obtain()
		local arena = pool[#pool]
		if arena then
			pool[#pool] = nil
			return arena
		end

		-- this default size might be a bit excessive, but it's just virtual memory anyway.
		return alloc.arena(2^20)
	end

	local function release(arena)
		arena:reset()
		pool[#pool+1] = arena
	end

	return obtain, release
end

local function plan(init)
	init = init or {}
	if not init.pool_obtain then
		local obtain, release = arenapool()
		init.pool_obtain = obtain
		init.pool_release = release
	end
	return init
end

local function decl_root(solver, name, opt)
	opt = opt or {}

	-- TODO: opt.single - take a single result, inline it in the struct

	table.insert(solver, {
		target = name,
		alias  = opt.alias or name:gsub("[^%w]", "_"):gsub("^([^%a_])", "_%1"),

		-- if you want a custom subset.
		-- cdata -> always use this constant subset
		-- string -> read this key from state
		subset = opt.subset
	})
end

local function decl_solver(roots)
	local solver = {}

	for _,x in ipairs(roots) do
		if type(x) == "string" then
			decl_root(solver, x)
		else
			for _,name in ipairs(x) do
				decl_root(solver, name, x)
			end
		end
	end

	return solver
end

local function add_solver(plan, view, template, solver)
	table.insert(plan, {
		view     = view,
		template = template,
		solver   = solver
	})
end

local function prune_nodeset(nodeset, vs)
	local retain = {}

	for _,vsdef in ipairs(vs) do
		for _,v in ipairs(vsdef.solver) do
			-- duplicates are ok
			table.insert(retain, v.target)
		end
	end

	return transform.prune(nodeset, retain)
end

local function get_roots(vsdef, nodeset, mapping)
	local roots = {}

	for _,v in ipairs(vsdef.solver) do
		local x = nodeset.vars[v.target]
		table.insert(roots, {
			name   = v.alias,
			idx    = mapping.nodes[x],
			ctype  = x.ctype,
			subset = v.subset,
			group  = mapping.groups[graph.groupof(v.target)]
		})
	end

	return roots
end

local function materialize(plan, nodeset)
	local views = {}

	for _,vsdef in ipairs(plan) do
		if not views[vsdef.view] then
			views[vsdef.view] = {}
		end
		table.insert(views[vsdef.view], vsdef)
	end

	for view, vs in pairs(views) do
		local ns = prune_nodeset(transform.materialize(nodeset, view), vs)
		local G, mapping, M, umem = driver.build(ns, plan.static_alloc)
		local syms = transform.symbols(mapping)
		local tracer = plan.trace and plan.trace {
			view    = view,
			nodeset = ns,
			G       = G,
			mapping = mapping,
			M       = M,
			symbols = syms,
		}
		local g_init = compile.graph_init(transform.shape(mapping, view), plan.pool_obtain)
		local dvr = compile.driver(M, umem, driver.loop(syms, tracer), plan.static_alloc,
			plan.pool_release)
		for _,vsdef in ipairs(vs) do
			local solver = compile.solver_init(G, get_roots(vsdef, ns, mapping),
				plan.static_alloc, plan.runtime_alloc)
			compile.bind_solver(vsdef.template, g_init, solver, dvr)
		end
	end
end

return {
	create      = plan,
	decl_solver = decl_solver,
	add_solver  = add_solver,
	materialize = materialize
}
