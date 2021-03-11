local cli = require "cli"
local plan = require "fhk.plan"
local ctypes = require "fhk.ctypes"
local compile = require "fhk.compile"
local debugger = require "fhk.debugger"
local graph = require "fhk.graph"
local view = require "fhk.view"
local ffi = require "ffi"
local C = ffi.C

local function inject(env, def)
	local p = plan.create({
		static_alloc  = env.m2.sim:allocator("static"),
		runtime_alloc = env.m2.sim:allocator("frame"),
		trace         = cli.verbosity <= -2 and debugger.tracer,
	})

	local modview = view.modelset_view(def.impls, p.static_alloc)

	env.m2.library {
		start = function()
			plan.materialize(p, def.nodeset)

			-- for gc
			p = nil
			modview = nil
		end
	}

	local allocf = env.m2.sim:allocator("frame")
	local allocu32 = function(n) return ffi.cast("uint32_t *", allocf(4*n, 4)) end

	-- don't use misc.delegate here so `p` and `def` won't be kept alive
	env.m2.fhk = {
		view           = function(...)
			return view.composite(...)
				:add(view.builtin_edge_view)
				:add(modview)
		end,

		solver         = function(view, ...)
			local template = compile.solver_template()
			plan.add_solver(p, view, template, plan.decl_solver({...}))
			return template
		end,

		subset         = function(idx)
			return ctypes.ssfromidx(idx, allocu32)
		end,

		composite      = view.composite,
		group          = view.group,
		struct_view    = view.struct_view,
		array_view     = view.array_view,
		soa_view       = view.soa_view,
		fixed_size     = view.fixed_size,
		match_edges    = view.match_edges,
		space          = view.space,
		only           = view.only,
		ident          = view.ident,
		tracer         = function(trace) p.trace = trace end
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
