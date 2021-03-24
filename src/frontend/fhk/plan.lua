local compile = require "fhk.compile"
local driver = require "fhk.driver"
local transform = require "fhk.transform"
local graph = require "fhk.graph"
local mem = require "fhk.mem"
local alloc = require "alloc"

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

local function desc_solver(solver)
	local names = {}
	for _,v in ipairs(solver) do
		table.insert(names, v.target)
	end
	return table.concat(names, ",")
end

local function add_solver(plan, view, trampoline, solver)
	table.insert(plan, {
		view       = view,
		trampoline = trampoline,
		solver     = solver
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
	local obtain, release = mem.shared_arena()
	local views = {}

	for _,vsdef in ipairs(plan) do
		if not views[vsdef.view] then
			views[vsdef.view] = {}
		end
		table.insert(views[vsdef.view], vsdef)
	end

	for view, vs in pairs(views) do
		local ns = prune_nodeset(transform.materialize(nodeset, view), vs)
		local ginfo, dispinfo = driver.build(ns, plan.static_alloc)
		if plan.trace then
			plan.trace({
				G = ginfo.G, mapping = ginfo.mapping, symbols = ginfo.syms,
				dispatch = dispinfo.dispatch, jumptable = dispinfo.jumptable,
				nodeset = ns
			})
		end
		local pushstate = compile.pushstate_uncached(
			ginfo.G,
			transform.shape(ginfo.mapping, view),
			obtain
		)
		for _,vsdef in ipairs(vs) do
			compile.bind_trampoline(
				vsdef.trampoline,
				compile.solver(
					dispinfo,
					plan.runtime_alloc,
					get_roots(vsdef, ns, ginfo.mapping),
					desc_solver(vsdef.solver)
				),
				pushstate,
				release
			)
		end
	end
end

return {
	decl_solver = decl_solver,
	desc_solver = desc_solver,
	add_solver  = add_solver,
	materialize = materialize
}
