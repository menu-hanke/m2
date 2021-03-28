local cli = require "cli"
local plan = require "fhk.plan"
local state = require "fhk.state"
local ctypes = require "fhk.ctypes"
local compile = require "fhk.compile"
local edgemaps = require "fhk.edgemaps"
local graph = require "fhk.graph"
local view = require "fhk.view"
local ffi = require "ffi"
local C = ffi.C

local function inject(env, def)
	local sim = env.m2.sim

	local p = {
		static_alloc  = sim:allocator("static"),
		runtime_alloc = sim:allocator("frame")
	}

	local modview = view.modelset_view(def.impls, p.static_alloc)

	env.m2.library {
		start = function()
			plan.materialize(p, def.nodeset)

			-- for gc
			p = nil
			modview.impls = nil
		end
	}

	local allocf = sim:allocator("frame")

	-- don't use misc.delegate here so `p` and `def` won't be kept alive
	env.m2.fhk = {
		view           = function(...)
			return view.composite(...)
				:add(view.builtin_edge_view)
				:add(modview)
		end,

		solver         = function(view, ...)
			if not view then error("missing view") end
			local solver = plan.decl_solver({...})
			local trampoline = compile.solver_trampoline(plan.desc_solver(solver))
			plan.add_solver(p, view, trampoline, solver)
			return trampoline
		end,

		-- note: this doesn't cascade like other view functions.
		-- you have to set it on the root view
		incremental    = function(view, key)
			if view.state then
				error(string.format("view already has a specialized state: %s", view.state))
			end
			view.state = function(G, shapef) return state.incremental(sim, G, shapef, key) end
			return view
		end,

		subset         = function(idx) return ctypes.ssfromidx(idx, allocf) end,
		range          = ctypes.range,
		unit           = ctypes.unit,
		composite      = view.composite,
		group          = view.group,
		struct_view    = view.struct_view,
		array_view     = view.array_view,
		soa_view       = view.soa_view,
		size_view      = view.size_view,
		fixed_size     = view.fixed_size,
		edge_view      = view.edge_view,
		ufunc          = edgemaps.ufunc,
		umap           = edgemaps.umap,
	}
end

local function def()
	return {
		nodeset = graph.nodeset(),
		impls   = {},
	}
end

return {
	inject = inject,
	def    = def,
}
