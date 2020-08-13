local plan = require "fhk.plan"
local mapping = require "fhk.mapping"
local ctypes = require "fhk.ctypes"
local ffi = require "ffi"
local C = ffi.C

local function inject(env, def)
	local p = plan.create()

	env.m2.on("env:prepare", function()
		p:finalize(def, {
			static_alloc = env.sim:allocator("static"),
			runtime_alloc = env.sim:allocator("frame")
		})

		-- these won't be needed any more, let them be gc'd
		p = nil
		def = nil
	end)

	-- don't use misc.delegate here so `p` and `def` won't be kept alive
	env.m2.fhk = {
		subgraph       = function(...) return p:subgraph(...) end,
		copylabels     = function(...) return def:copylabels(...) end,
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
