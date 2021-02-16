local cli = require "cli"
local plan = require "fhk.plan"
local mapping = require "fhk.mapping"
local ctypes = require "fhk.ctypes"
local debugger = require "fhk.debugger"
local ffi = require "ffi"
local C = ffi.C

local function inject(env, def)
	local p = plan.create()

	local compiler = {
		static_alloc  = env.m2.sim:allocator("static"),
		runtime_alloc = env.m2.sim:allocator("frame"),
		trace         = cli.verbosity <= -2 and debugger.tracer
	}

	env.m2.library {
		start = function()
			p:compile(def, compiler)

			-- these won't be needed any more, let them be gc'd
			p = nil
			def = nil
			compiler = nil
		end
	}

	-- don't use misc.delegate here so `p` and `def` won't be kept alive
	env.m2.fhk = {
		subgraph       = function(...) return p:subgraph(...) end,
		add_solver     = function(...) return p:add_solver(...) end,
		solver         = function(...) return p:solver(...) end,
		copylabels     = function(...) return def:copylabels(...) end,
		tracer         = function(trace) compiler.trace = trace end,
		group          = mapping.parallel_group,
		struct_mapper  = mapping.struct_mapper,
		soa_mapper     = mapping.soa_mapper,
		fixed_size     = mapping.fixed_size,
		match_edges    = mapping.match_edges,
		space          = mapping.space,
		only           = mapping.only,
		ident          = mapping.ident,
		subset_builder = ctypes.ss_builder,
		subset         = ctypes.subset
	}
end

return {
	inject = inject,
}
