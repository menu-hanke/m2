-- vim: ft=lua
local sim = require "sim"
local scripting = require "scripting"
local fhk = require "fhk"
local ffi = require "ffi"
local fails = fails

local function _(f1, f2)
	return function()
		local def = fhk.def()
		setfenv(f1, fhk.env(def))()

		local sim = sim.create()
		local env = scripting.env(sim)
		fhk.inject(env, def)
		require("soa").inject(env)
		require("control").inject(env)

		setfenv(f2, env)()

		if f then
			assert(f(function() scripting.hook(env, "start") end))
		elseif env.m2.export.test then
			scripting.hook(env, "start")
			env.m2.export.test()
		end
	end
end

----- helpers -------

local unmapped = {
	map_var = function() return true end,
	map_model = function() return true end,
	shape_func = function() return function() return 1 end end
}

local function gmodel_gx_Const(ctype, rv)
	ctype = ctype or "double"
	rv = rv or 123

	return function()
		model "g#model" {
			returns "g#x" *as(ctype),
			impl.Const(rv)
		}
	end
end

--------------------------------------------------------------------------------

test_struct_mapper = _(function()
	model "s#model" {
		params {"s#x", "s#y"},
		returns {"s#z", "s#w"} *as "double",
		impl.Lua("models", "id")
	}
end, function()
	local struct_ct = ffi.typeof "struct { double x; double y; }"
	local struct = struct_ct(1, 2)

	local sg_unbound = m2.fhk.subgraph()
		:edge(m2.fhk.match_edges { {"=>%1", m2.fhk.ident }})
		:given(m2.fhk.group("s", m2.fhk.struct_mapper(struct_ct, "inst")))
	
	local solver_unbound = m2.fhk.solver(sg_unbound, "s#z", "s#w")
	
	local sg_bound = m2.fhk.subgraph()
		:edge(m2.fhk.match_edges { {"=>%1", m2.fhk.ident }})
		:given(m2.fhk.group("s", m2.fhk.struct_mapper(struct_ct, struct)))
	
	local solver_bound = m2.fhk.solver(sg_bound, "s#z", "s#w")

	function m2.export.test()
		local res_unbound = solver_unbound({inst=struct})
		assert(res_unbound.s_z[0] == 1 and res_unbound.s_w[0] == 2)

		local res_bound = solver_bound()
		assert(res_bound.s_z[0] == 1 and res_bound.s_w[0] == 2)
	end
end)

test_soa_mapper = _(function()
	model "s#model" {
		params { "s#x", "s#y" },
		returns { "s#z", "s#w"} *as "double",
		impl.Lua("models", "id")
	}
end, function()
	local soa_ct = m2.soa.from_bands { x="double", y="double" }
	local soa = m2.new_soa(soa_ct)

	local sg_unbound = m2.fhk.subgraph()
		:edge(m2.fhk.match_edges {{ "=>%1", m2.fhk.ident }})
		:given(m2.fhk.group("s", m2.fhk.soa_mapper(soa_ct, "inst")))
	
	local solver_unbound = m2.fhk.solver(sg_unbound, "s#z", "s#w")

	local sg_bound = m2.fhk.subgraph()
		:edge(m2.fhk.match_edges {{ "=>%1", m2.fhk.ident }})
		:given(m2.fhk.group("s", m2.fhk.soa_mapper(soa_ct, soa)))
	
	local solver_bound = m2.fhk.solver(sg_bound, "s#z", "s#w")

	function m2.export.test()
		soa:alloc(3)
		local x, y = soa:newband("x"), soa:newband("y")
		x[0] = 1; y[0] = 100
		x[1] = 2; y[1] = 200
		x[2] = 3; y[2] = 300

		local res_unbound = solver_unbound({inst=soa})
		assert(
			res_unbound.s_z[0] == 1 and res_unbound.s_w[0] == 100 and
			res_unbound.s_z[1] == 2 and res_unbound.s_w[1] == 200 and
			res_unbound.s_z[2] == 3 and res_unbound.s_w[2] == 300
		)

		local res_bound = solver_bound()
		assert(
			res_bound.s_z[0] == 1 and res_bound.s_w[0] == 100 and
			res_bound.s_z[1] == 2 and res_bound.s_w[1] == 200 and
			res_bound.s_z[2] == 3 and res_bound.s_w[2] == 300
		)
	end
end)

test_mixed_mapping = _(function()
	model "plot#ba_sum" {
		params {"plot#time", "tree#ba"},
		returns "plot#ba" *as "double",
		impl.Lua("models", "ba_sum")
	}
end, function()
	local Plot = ffi.typeof "struct { double time; }"
	local Trees = m2.soa.from_bands { ba = "double" }

	local plot = Plot()
	local trees = m2.new_soa(Trees)

	local subgraph = m2.fhk.subgraph()
		:edge(m2.fhk.match_edges {
			{ "=>%1",       m2.fhk.ident },
			{ "plot=>tree", m2.fhk.space }
		})
		:given(m2.fhk.group("plot", m2.fhk.struct_mapper(Plot, plot)))
		:given(m2.fhk.group("tree", m2.fhk.soa_mapper(Trees, trees)))
	
	local solver = m2.fhk.solver(subgraph, "plot#ba")

	function m2.export.test()
		trees:alloc(3)
		trees:newband("ba")
		trees.ba[0] = 1
		trees.ba[1] = 2
		trees.ba[2] = 3

		plot.time = 10

		local solution = solver()
		assert(solution.plot_ba[0] == 10*(1+2+3))
	end
end)

test_missing_model = _(function() end, function()
	m2.fhk.solver(
		m2.fhk.subgraph()
			:edge(m2.fhk.match_edges { {"=>%1", m2.fhk.ident }})
			:given(m2.fhk.group("g", unmapped)),
		"g#x"
	)
	
	return fails "inconsistent subgraph: 'g#x' was not pruned"
end)

test_missing_var = _(gmodel_gx_Const(), function()
	m2.fhk.solver(
		m2.fhk.subgraph()
			:edge(m2.fhk.match_edges {{"=>%1", m2.fhk.ident}})
			:given(m2.fhk.group("g", unmapped)),
		"g#y"
	)
	
	return fails "inconsistent subgraph: 'g#y' was not pruned"
end)

test_missing_edge = _(gmodel_gx_Const(), function()
	m2.fhk.solver(
		m2.fhk.subgraph()
			:given(m2.fhk.group("g", unmapped)),
		"g#x"
	)
	
	return fails "unmapped edge"
end)

test_const_missing_type = _(function()
	model "g#model" {
		returns "g#x",
		impl.Const(123)
	}
end, function()
	m2.fhk.solver(
		m2.fhk.subgraph()
			:edge(m2.fhk.match_edges {{ "=>%1", m2.fhk.ident }})
			:given(m2.fhk.group("g", unmapped)),
		"g#x"
	)
	
	return fails "can't determine unique return type for 'g#x'"
end)

test_wrong_type = _(gmodel_gx_Const("uint64_t"), function()
	m2.fhk.solver(
		m2.fhk.subgraph()
			:edge(m2.fhk.match_edges {{ "=>%1", m2.fhk.ident }})
			:given(m2.fhk.group("g", unmapped)),
		{ "g#x", ctype="double" }
	)
	
	-- Note: when auto conversions for returns are implemented, this test should pass instead
	return fails "conflicting types for 'g#x'"
end)

test_const_unmapped = _(gmodel_gx_Const(), function()
	local solver = m2.fhk.solver(
		m2.fhk.subgraph()
			:edge(m2.fhk.match_edges { {"=>%1", m2.fhk.ident }})
			:given(m2.fhk.group("g", unmapped)),
		"g#x"
	)
	
	function m2.export.test()
		local result = solver()
		assert(result.g_x[0] == 123)
	end
end)

test_dupe_mapper = _(gmodel_gx_Const(), function()
	m2.fhk.solver(
		m2.fhk.subgraph()
			:edge(m2.fhk.match_edges {{ "=>%1", m2.fhk.ident }})
			:given(m2.fhk.group("g", unmapped))
			:given(m2.fhk.group("g", unmapped)),
		"g#x"
	)
	
	return fails "mapping conflict"
end)

test_dupe_edge = _(gmodel_gx_Const(), function()
	m2.fhk.solver(
		m2.fhk.subgraph()
			:edge(m2.fhk.match_edges {{ "=>%1", m2.fhk.ident }})
			:edge(m2.fhk.match_edges {{ "=>%1", m2.fhk.ident }})
			:given(m2.fhk.group("g", unmapped)),
		"g#x"
	)
	
	return fails "mapping conflict"
end)

test_include_subgraph = _(gmodel_gx_Const(), function()
	local sub1 = m2.fhk.subgraph()
		:given(m2.fhk.group("g", unmapped))
	
	local sub2 = m2.fhk.subgraph()
		:include(sub1)
		:edge(m2.fhk.match_edges {{"=>%1", m2.fhk.ident}})
	
	local solver = m2.fhk.solver(sub2, "g#x")
	
	function m2.export.test()
		local result = solver()
		assert(result.g_x[0] == 123)
	end
end)

test_derive = _(function()
	derive ("g#y" *as "double") {
		impl.Const(123)
	}

	model "g#model" {
		params "g#y",
		returns "g#z" *as "double",
		impl.Lua("models", "id")
	}
end, function()
	local solver = m2.fhk.solver(
		m2.fhk.subgraph()
			:edge(m2.fhk.match_edges {{ "=>%1", m2.fhk.ident }})
			:given(m2.fhk.group("g", unmapped)),
		"g#z"
	)
	
	function m2.export.test()
		assert(solver().g_z[0] == 123)
	end
end)

test_builtin_set = _(function()
	model "g#modall" {
		params {
			"g#x" *set "only",
			"v#x" *set "all"
		},
		returns "g#sum" *set "ident" *as "double",
		impl.Lua("models", "ba_sum")
	}
end, function()
	local g_ct = ffi.typeof "struct { double x; }"
	local g = g_ct()

	g.x = 100

	local v_ct = m2.soa.from_bands { x = "double" }
	local v = m2.new_soa(v_ct)

	v:alloc(3)
	v:newband("x")
	v.x[0] = 4; v.x[1] = 5; v.x[2] = 6

	local solver = m2.fhk.solver(
		m2.fhk.subgraph()
			:given(m2.fhk.group("g", m2.fhk.struct_mapper(g_ct, g)))
			:given(m2.fhk.group("v", m2.fhk.soa_mapper(v_ct, v))),
		"g#sum"
	)
	
	function m2.export.test()
		assert(solver().g_sum[0] == 100*(4+5+6))
	end
end)

test_builtin_constraints = _(function()
	model "g#f32_nonnegative" {
		check "g#f32" *ge(0),
		returns "g#x" *as "double",
		impl.Const(0)
	}

	model "g#f32_nonpositive" {
		check "g#f32" *le(0),
		returns "g#x" *as "double",
		impl.Const(1)
	}

	model "g#f64_nonnegative" {
		check "g#f64" *ge(0),
		returns "g#y" *as "double",
		impl.Const(2)
	}

	model "g#f64_nonpositive" {
		check "g#f64" *le(0),
		returns "g#y" *as "double",
		impl.Const(3)
	}

	model "g#u8_is123" {
		check "g#u8" *is{1,2,3},
		returns "g#z" *as "double",
		impl.Const(4)
	}

	model "g#u8_is456" {
		check "g#u8" *is{4,5,6},
		returns "g#z" *as "double",
		impl.Const(5)
	}
end, function()
	local g_ct = ffi.typeof [[
		struct {
			double f64;
			float f32;
			uint8_t u8;
		}
	]]

	local g = g_ct({f32=-1, f64=1, u8=5})

	local solver = m2.fhk.solver(
		m2.fhk.subgraph()
			:edge(m2.fhk.match_edges {{ "=>%1", m2.fhk.ident }})
			:given(m2.fhk.group("g", m2.fhk.struct_mapper(g_ct, g))),
		"g#x", "g#y", "g#z"
	)
	
	function m2.export.test()
		local solution = solver()
		assert(solution.g_x[0] == 1)
		assert(solution.g_y[0] == 2)
		assert(solution.g_z[0] == 5)
	end
end)

test_builtin_constraints_set = _(function()
	model "g#f32_nonnegative" {
		check "v#f32" *set "all" *ge(0),
		returns "g#x" *set "ident" *as "double",
		impl.Const(123)
	}

	model "g#u8_is123" {
		check "v#u8" *set "all" *is{1,2,3},
		returns "g#y" *set "ident" *as "double",
		impl.Const(456)
	}
end, function()
	local v_ct = m2.soa.from_bands {
		f32 = "float",
		u8 = "uint8_t"
	}

	local v = m2.new_soa(v_ct)
	v:alloc(3)
	v:newband("f32")
	v:newband("u8")

	v.f32[0] = 1; v.f32[1] = 2; v.f32[2] = 3;
	v.u8[0] = 1; v.u8[1] = 2; v.u8[2] = 3;

	local solver = m2.fhk.solver(
		m2.fhk.subgraph()
			:given(m2.fhk.group("g", unmapped))
			:given(m2.fhk.group("v", m2.fhk.soa_mapper(v_ct, v))),
		"g#x", "g#y"
	)

	function m2.export.test()
		local solution = solver()
		assert(solution.g_x[0] == 123)
		assert(solution.g_y[0] == 456)
	end
end)

test_subset = _(function()
	model "v#0_nonnegative" {
		check "v#x" *ge(0),
		returns "v#y" *as "double",
		impl.Const(0)
	}
end, function()
	local v_ct = m2.soa.from_bands { x = "double" }
	local v = m2.new_soa(v_ct)

	v:alloc(5)
	v:newband("x")

	v.x[0] = 1
	v.x[1] = 2
	v.x[2] = -3
	v.x[3] = -4
	v.x[4] = 5

	local solver = m2.fhk.solver(
		m2.fhk.subgraph()
			:edge(m2.fhk.match_edges {{ "=>%1", m2.fhk.ident }})
			:given(m2.fhk.group("v", m2.fhk.soa_mapper(v_ct, v))),
		{ "v#y", subset="sub" }
	)

	local sub = m2.fhk.subset_builder()
		:add(0, 2)
		:add(4)
		:to_subset()
	
	function m2.export.test()
		solver({sub=sub})
	end
end)

test_solver_fail_chain = _(function()
	derive ("g#u8" *as "uint8_t") {
		impl.Const(4)
	}

	model "g#u8_is123" {
		check "g#u8" *is{1,2,3},
		returns "g#x" *as "double",
		impl.Const(0)
	}
end, function()
	local solver = m2.fhk.solver(
		m2.fhk.subgraph()
			:edge(m2.fhk.match_edges {{ "=>%1", m2.fhk.ident }})
			:given(m2.fhk.group("g", unmapped)),
		"g#x"
	)
	
	function m2.export.test()
		assert(fails(solver, "fhk failed: no chain with finite cost.*variable: g#x"))
	end
end)

test_invalid_constraint = _(function()
	derive ("g#u8" *as "double") {
		impl.Const(4)
	}

	model "g#u8_is123" {
		check "g#u8" *is{1,2,3},
		returns "g#x" *as "double",
		impl.Const(0)
	}
end, function()
	m2.fhk.solver(
		m2.fhk.subgraph()
			:edge(m2.fhk.match_edges {{ "=>%1", m2.fhk.ident }})
			:given(m2.fhk.group("g", unmapped)),
		"g#x"
	)
	
	return fails "set constraint isn't applicable"
end)

test_no_solution = _(function()
	derive ("g#x" *as "double") {
		impl.Const(1)
	}

	model "g#mody" {
		check "g#x" *le(0),
		returns "g#y" *as "double",
		impl.Const(0)
	}
end, function()
	local solver = m2.fhk.solver(
		m2.fhk.subgraph()
			:edge(m2.fhk.match_edges {{ "=>%1", m2.fhk.ident }})
			:given(m2.fhk.group("g", unmapped)),
		"g#y"
	)
	
	function m2.export.test()
		assert(fails(solver, "fhk failed: no chain with finite cost.*variable: g#y"))
	end
end)

test_model_crash = _(function()
	model "g#mody" {
		returns "g#y" *as "double",
		impl.Lua("models", "runtime_error")
	}
end, function()
	local solver = m2.fhk.solver(
		m2.fhk.subgraph()
			:edge(m2.fhk.match_edges {{ "=>%1", m2.fhk.ident }})
			:given(m2.fhk.group("g", unmapped)),
		"g#y"
	)
	
	function m2.export.test()
		assert(fails(solver, "model crashed"))
	end
end)

test_R_impl = _(function()
	derive ("g#x" *as "double") {
		impl.R("models.r", "ret1")
	}
end, function()
	local solver = m2.fhk.solver(
		m2.fhk.subgraph()
			:edge(m2.fhk.match_edges {{ "=>%1", m2.fhk.ident }})
			:given(m2.fhk.group("g", m2.fhk.fixed_size(1))),
		"g#x"
	)
	
	function m2.export.test()
		local solution = solver()
		assert(solution.g_x[0] == 1)
	end
end)

test_alias = _(gmodel_gx_Const(), function()
	local solver = m2.fhk.solver(
		m2.fhk.subgraph()
			:edge(m2.fhk.match_edges {{ "=>%1", m2.fhk.ident }})
			:given(m2.fhk.group("g", unmapped)),
		{ "g#x", alias="var0" }
	)

	function m2.export.test()
		local solution = solver()
		assert(solution.var0[0] == 123)
	end
end)

test_tracing = _(function()
	model "g#model" {
		params "g#y",
		returns "g#x" *as "double",
		impl.Lua("models", "id")
	}
end, function()
	local num = 0

	m2.fhk.tracer(function()
		return function(D, status, arg)
			if num == 0 then assert(status == ffi.C.FHKS_VREF and arg.s_vref.idx == 0) end
			if num == 1 then assert(status == ffi.C.FHKS_MODCALL and arg.s_modcall.mref.idx == 0) end
			if num > 1 then assert(false) end
			num = num+1
		end, function(_, _, e)
			e.trace = true
		end
	end)

	local g_ct = ffi.typeof [[
		struct {
			double y;
		}
	]]

	local g = g_ct(0)

	local solver = m2.fhk.solver(
		m2.fhk.subgraph()
			:edge(m2.fhk.match_edges {{ "=>%1", m2.fhk.ident }})
			:given(m2.fhk.group("g", m2.fhk.struct_mapper(g_ct, g))),
		"g#x"
	)

	function m2.export.test()
		solver()
		assert(num == 2)
	end
end)
