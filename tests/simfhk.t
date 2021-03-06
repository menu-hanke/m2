-- vim: ft=lua
local sim = require "sim"
local scripting = require "scripting"
local fhk = require "fhk"
local ffi = require "ffi"
local fff = require "fff"
local fails = fails

local function _(f1, f2)
	return function()
		local def = fhk.def()
		setfenv(f1, fhk.env(def.nodeset, def.impls))()

		local sim = sim.create()
		local env = scripting.env(sim)
		fhk.inject(env, def)
		require("soa").inject(env)
		require("control").inject(env)

		local f = setfenv(f2, env)()

		if f then
			assert(f(function() scripting.hook(env, "start") end))
		elseif env.m2.export.test then
			scripting.hook(env, "start")
			env.m2.export.test()
		end
	end
end

----- helpers -------

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

test_struct_view = _(function()
	model "s#model" {
		params {"s#x", "s#y"},
		returns {"s#z", "s#w"} *as "double",
		impl.LuaJIT("models", "id")
	}
end, function()
	local struct_ct = ffi.typeof "struct { double x; double y; }"
	local struct = struct_ct(1, 2)

	local unbound = m2.fhk.view()
		:add(m2.fhk.edge_view("=>$", "ident"))
		:add(m2.fhk.group("s",
			m2.fhk.struct_view(struct_ct, function(_, state) return state.struct end),
			m2.fhk.fixed_size(1)
		))
	
	local solver_unbound = m2.fhk.solver(unbound, "s#z", "s#w")
	
	local bound = m2.fhk.view()
		:add(m2.fhk.edge_view("=>$", "ident"))
		:add(m2.fhk.group("s", m2.fhk.struct_view(struct_ct, struct)))
	
	local solver_bound = m2.fhk.solver(bound, "s#z", "s#w")

	function m2.export.test()
		local res_unbound = solver_unbound({struct=struct})
		assert(res_unbound.s_z[0] == 1 and res_unbound.s_w[0] == 2)

		local res_bound = solver_bound()
		assert(res_bound.s_z[0] == 1 and res_bound.s_w[0] == 2)
	end
end)

test_soa_view = _(function()
	model "s#model" {
		params { "s#x", "s#y" },
		returns { "s#z", "s#w"} *as "double",
		impl.LuaJIT("models", "id")
	}
end, function()
	local soa_ct = m2.soa.from_bands { x="double", y="double" }
	local soa = m2.new_soa(soa_ct)

	local unbound = m2.fhk.view()
		:add(m2.fhk.edge_view("=>$", "ident"))
		:add(m2.fhk.group("s",
			m2.fhk.soa_view(soa_ct, function(_, state) return state.soa, 0 end),
			m2.fhk.size_view(function(state) return #state.soa end)
		))
	
	local solver_unbound = m2.fhk.solver(unbound, "s#z", "s#w")

	local bound = m2.fhk.view()
		:add(m2.fhk.edge_view("=>$", "ident"))
		:add(m2.fhk.group("s", m2.fhk.soa_view(soa_ct, soa)))
	
	local solver_bound = m2.fhk.solver(bound, "s#z", "s#w")

	function m2.export.test()
		soa:alloc(3)
		local x, y = soa:newband("x"), soa:newband("y")
		x[0] = 1; y[0] = 100
		x[1] = 2; y[1] = 200
		x[2] = 3; y[2] = 300

		local res_unbound = solver_unbound({soa=soa})
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

test_mixed_view = _(function()
	model "plot#ba_sum" {
		params {"plot#time", "tree#ba"},
		returns "plot#ba" *as "double",
		impl.LuaJIT("models", "ba_sum")
	}
end, function()
	local Plot = ffi.typeof "struct { double time; }"
	local Trees = m2.soa.from_bands { ba = "double" }

	local plot = Plot()
	local trees = m2.new_soa(Trees)

	local subgraph = m2.fhk.view()
		:add(m2.fhk.edge_view("=>$", "ident"))
		:add(m2.fhk.group("plot",
			m2.fhk.edge_view("=>tree", "space"),
			m2.fhk.struct_view(Plot, plot)
		))
		:add(m2.fhk.group("tree", m2.fhk.soa_view(Trees, trees)))
	
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

test_empty_space = _(function()
	model "g#model" {
		params "g#x",
		returns "g#y" *as "double",
		impl.LuaJIT("models", "id")
	}
end, function()
	local ct = m2.soa.from_bands { y = "double" }
	local inst = m2.new_soa(ct)

	-- g#x is typeless.
	-- this is ok, because it's unreachable and should be pruned.
	local solver = m2.fhk.solver(
		m2.fhk.view()
			:add(m2.fhk.edge_view("=>$", "ident"))
			:add(m2.fhk.group("g", m2.fhk.soa_view(ct, inst))),
		"g#y"
	)

	function m2.export.test()
		solver()
	end
end)

test_missing_shape = _(gmodel_gx_Const(), function()
	m2.fhk.solver(
		m2.fhk.view():add(m2.fhk.edge_view("=>$", "ident")),
		"g#x"
	)

	return fails "no shape function for group: g"
end)

test_missing_var = _(gmodel_gx_Const(), function()
	m2.fhk.solver(
		m2.fhk.view():add(m2.fhk.edge_view("=>$", "ident")),
		"g#y"
	)
	
	return fails "retained variable not in graph: g#y"
end)

test_unreachable_var = _(function()
	model "g#model" {
		params "g#x",
		returns "g#y" *as "double",
		impl.Const(123)
	}
end, function()
	m2.fhk.solver(
		m2.fhk.view():add(m2.fhk.edge_view("=>$", "ident")),
		"g#y"
	)

	return fails "no chain with finite cost.*g#y"
end)

test_unreachable_shadow = _(function()
	model "g#model" {
		check "g#x" *ge(0),
		returns "g#y" *as "double",
		impl.Const(123)
	}
end, function()
	m2.fhk.solver(
		m2.fhk.view():add(m2.fhk.edge_view("=>$", "ident")),
		"g#y"
	)

	return fails "no chain with finite cost.*g#y"
end)

test_missing_edge = _(function()
	model "g#m1" {
		params "h#x",
		returns "g#x" *as "double",
		impl.Const(123)
	}
end, function()
	local ct = ffi.typeof "struct { double x; }"

	m2.fhk.solver(
		m2.fhk.view()
			:add(m2.fhk.group("g", m2.fhk.fixed_size(1)))
			:add(m2.fhk.group("h", m2.fhk.struct_view(ct, "h"))),
		"g#x"
	)

	return fails "no chain with finite cost.*g#x"
end)

test_missing_type = _(function()
	model "g#model" {
		returns "g#x",
		impl.Const(123)
	}
end, function()
	m2.fhk.solver(
		m2.fhk.view()
			:add(m2.fhk.edge_view("=>$", "ident"))
			:add(m2.fhk.group("g", m2.fhk.fixed_size(1))),
		"g#x"
	)
	
	return fails "no chain with finite cost.*g#x"
end)

test_dupe_view = _(function()
	model "g#model" {
		params "g#x",
		returns "g#y" *as "double",
		impl.Const(123)
	}
end, function()
	local ct = ffi.typeof "struct { double x; }"
	local data = ct()

	m2.fhk.solver(
		m2.fhk.view()
			:add(m2.fhk.edge_view("=>$", "ident"))
			:add(m2.fhk.group("g", m2.fhk.struct_view(ct, data)))
			:add(m2.fhk.group("g", m2.fhk.struct_view(ct, data))),
		"g#y"
	)
	
	return fails "view not unique"
end)

test_dupe_edge = _(gmodel_gx_Const(), function()
	m2.fhk.solver(
		m2.fhk.view()
			:add(m2.fhk.edge_view("=>$", "ident"))
			:add(m2.fhk.edge_view("=>$", "ident"))
			:add(m2.fhk.group("g", m2.fhk.fixed_size(1))),
		"g#x"
	)
	
	return fails "view not unique"
end)

test_composite_view = _(gmodel_gx_Const(), function()
	local view1 = m2.fhk.group("g", m2.fhk.fixed_size(1))
	local view2 = m2.fhk.edge_view("=>$", "ident")

	local view = m2.fhk.view():add(m2.fhk.composite(view1, view2))
	local solver = m2.fhk.solver(view, "g#x")
	
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
		impl.LuaJIT("models", "id")
	}
end, function()
	local solver = m2.fhk.solver(
		m2.fhk.view()
			:add(m2.fhk.edge_view("=>$", "ident"))
			:add(m2.fhk.group("g", m2.fhk.fixed_size(1))),
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
		impl.LuaJIT("models", "ba_sum")
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
		m2.fhk.view()
			:add(m2.fhk.group("g", m2.fhk.struct_view(g_ct, g)))
			:add(m2.fhk.group("v", m2.fhk.soa_view(v_ct, v))),
		"g#sum"
	)
	
	function m2.export.test()
		assert(solver().g_sum[0] == 100*(4+5+6))
	end
end)

test_builtin_checks = _(function()
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
		m2.fhk.view()
			:add(m2.fhk.edge_view("=>$", "ident"))
			:add(m2.fhk.group("g", m2.fhk.struct_view(g_ct, g))),
		"g#x", "g#y", "g#z"
	)
	
	function m2.export.test()
		local solution = solver()
		assert(solution.g_x[0] == 1)
		assert(solution.g_y[0] == 2)
		assert(solution.g_z[0] == 5)
	end
end)

test_builtin_checks_set = _(function()
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
		m2.fhk.view()
			:add(m2.fhk.group("g", m2.fhk.fixed_size(1)))
			:add(m2.fhk.group("v", m2.fhk.soa_view(v_ct, v))),
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
		m2.fhk.view()
			:add(m2.fhk.edge_view("=>$", "ident"))
			:add(m2.fhk.group("v", m2.fhk.soa_view(v_ct, v))),
		{ "v#y", subset="sub" }
	)

	local sub = m2.fhk.subset { 0, 1, 4 }
	
	function m2.export.test()
		solver(nil, {sub=sub})
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
		m2.fhk.view()
			:add(m2.fhk.edge_view("=>$", "ident"))
			:add(m2.fhk.group("g", m2.fhk.fixed_size(1))),
		"g#x"
	)
	
	function m2.export.test()
		assert(fails(solver, "no chain with finite cost.*g#x"))
	end
end)

test_invalid_check = _(function()
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
		m2.fhk.view()
			:add(m2.fhk.edge_view("=>$", "ident"))
			:add(m2.fhk.group("g", m2.fhk.fixed_size(1))),
		"g#x"
	)

	return fails "no materialization for guard"
end)

test_model_crash = _(function()
	model "g#mody" {
		returns "g#y" *as "double",
		impl.LuaJIT("models", "runtime_error")
	}
end, function()
	local solver = m2.fhk.solver(
		m2.fhk.view()
			:add(m2.fhk.edge_view("=>$", "ident"))
			:add(m2.fhk.group("g", m2.fhk.fixed_size(1))),
		"g#y"
	)
	
	function m2.export.test()
		assert(fails(solver, "model crashed"))
	end
end)

if fff.has("R") then
	test_R_impl = _(function()
		derive ("g#x" *as "double") {
			impl.R("models.r", "ret1")
		}
	end, function()
		local solver = m2.fhk.solver(
			m2.fhk.view()
				:add(m2.fhk.edge_view("=>$", "ident"))
				:add(m2.fhk.group("g", m2.fhk.fixed_size(1))),
			"g#x"
		)
		
		function m2.export.test()
			local solution = solver()
			assert(solution.g_x[0] == 1)
		end
	end)
end

test_alias = _(gmodel_gx_Const(), function()
	local solver = m2.fhk.solver(
		m2.fhk.view()
			:add(m2.fhk.edge_view("=>$", "ident"))
			:add(m2.fhk.group("g", m2.fhk.fixed_size(1))),
		{ "g#x", alias="var0" }
	)

	function m2.export.test()
		local solution = solver()
		assert(solution.var0[0] == 123)
	end
end)

test_labels = _(function()
	labels {
		a = 1,
		nested = {
			b = 2
		}
	}

	model "g#model" {
		check "g#y" *is { "a", "b" },
		returns "g#x" *as "double",
		impl.Const(123)
	}
end, function()
	local ct = ffi.typeof [[ struct { uint8_t y; } ]]
	local g = ct()

	local solver = m2.fhk.solver(
		m2.fhk.view()
			:add(m2.fhk.edge_view("=>$", "ident"))
			:add(m2.fhk.group("g", m2.fhk.struct_view(ct, g))),
		"g#x"
	)

	function m2.export.test()
		g.y = 1
		assert(solver().g_x[0] == 123)

		g.y = 2
		assert(solver().g_x[0] == 123)

		g.y = 3
		assert(fails(solver, "no chain with finite cost"))
	end
end)

test_hierarchy_map = _(function()
	derive ("container#sum" *as "double") {
		params "element#y" *set "container->elements",
		impl.LuaJIT("models", "sum_vec")
	}

	derive ("element#y" *as "double") {
		params {
			"container#w",
			"element#x"
		},
		impl.LuaJIT("models", "prod_scalar")
	}
end, function()
	local container_ct = ffi.typeof "struct { double w; }"
	local element_ct = ffi.typeof "struct { double x; }"

	local containers = ffi.new(ffi.typeof("$[2]", container_ct), { {w=1}, {w=-2} })
	local elements = ffi.new(ffi.typeof("$[10]", element_ct), {
		{ x=7 }, { x=3 }, { x=5 }, { x=5 },
		{ x=6 }, { x=0 }, { x=8 }
	})

	local c2e = { [0]={0, 1, 2, 3}, {4, 5, 6} }
	local e2c = { [0]= 0, 0, 0, 0,   1, 1, 1  }

	local f_c2e = m2.fhk.ufunc(function(inst) return m2.fhk.subset(c2e[inst]) end)
	local f_e2c = m2.fhk.ufunc(function(inst) return m2.fhk.subset{e2c[inst]} end)
	local map_c2e = m2.fhk.umap(f_c2e, f_e2c)
	local map_e2c = m2.fhk.umap(f_e2c, f_c2e)

	local solver = m2.fhk.solver(
		m2.fhk.view()
			:add(m2.fhk.edge_view("=>$", "ident"))
			:add(m2.fhk.group("container",
				m2.fhk.edge_view("=> element :container->elements", map_c2e),
				m2.fhk.struct_view(container_ct, function(inst) return containers[inst] end),
				m2.fhk.fixed_size(2)
			))
			:add(m2.fhk.group("element",
				m2.fhk.edge_view("=> container", map_e2c, true),
				m2.fhk.struct_view(element_ct, function(inst) return elements[inst] end),
				m2.fhk.fixed_size(7)
			)),
		"container#sum"
	)

	function m2.export.test()
		local sum = solver()
		assert(sum.container_sum[0] == 1*(7+3+5+5))
		assert(sum.container_sum[1] == -2*(6+0+8))
	end
end)

test_hierarchy_inverse = _(function()
	derive "container#y" {
		params "container#w",
		returns "element#y" *as "double",
		impl.LuaJIT("models", "seqv")
	}
end, function()
	local container_ct = ffi.typeof "struct { double w; }"
	local containers = ffi.new(ffi.typeof("$[3]", container_ct), { {w=1}, {w=2}, {w=3} })

	local c2e = { [0]={}, {3,4}, {0,1,2,5,6} }
	local e2c = { [0]=2,2,2,1,1,2,2 }

	local f_c2e = m2.fhk.ufunc(function(inst) return m2.fhk.subset(c2e[inst]) end)
	local f_e2c = m2.fhk.ufunc(function(inst) return m2.fhk.subset{e2c[inst]} end)
	local map_c2e = m2.fhk.umap(f_c2e, f_e2c)

	local solver = m2.fhk.solver(
		m2.fhk.view()
			:add(m2.fhk.group("container",
				m2.fhk.edge_view("=>container", "ident"),
				m2.fhk.edge_view("=>element", map_c2e),
				m2.fhk.struct_view(container_ct, function(inst) return containers[inst] end),
				m2.fhk.fixed_size(3)
			))
			:add(m2.fhk.group("element", m2.fhk.fixed_size(7))),
		"element#y"
	)

	function m2.export.test()
		local y = solver().element_y
		assert(
			y[3] == 0*2 and y[4] == 1*2
		)
		assert(
			y[0] == 0*3 and y[1] == 1*3 and y[2] == 2*3 and y[5] == 3*3 and y[6] == 4*3
		)
	end
end)

test_incremental = _(function()
	derive ("g#x" *as "double") {
		params "g#y",
		impl.LuaJIT("models", "id")
	}
end, function()
	local g_ct = ffi.typeof "struct { double y; }"
	local g = m2.sim:new(g_ct, "vstack")

	local view = m2.fhk.view()
		:add(m2.fhk.edge_view("=>$", "ident"))
		:add(m2.fhk.group("g", m2.fhk.struct_view(g_ct, g)))
	
	local key = 0
	
	m2.fhk.incremental(view, function() return key end)

	local solver = m2.fhk.solver(view, "g#x")

	function m2.export.test()
		g.y = 1
		local s1 = solver()
		assert(s1.g_x[0] == 1)

		-- don't do this in real code.
		-- this is just to show that it won't re-execute the solver.
		g.y = 2
		local s2 = solver()
		assert(s2.g_x[0] == 1)

		-- this should re-solve
		key = 1
		local s3 = solver()
		assert(s3.g_x[0] == 2)

		-- branching should also trigger a re-solve, even without changing the key
		local fp = m2.sim:fp()
		m2.sim:savepoint()
		m2.sim:enter()
		g.y = 3
		local s4 = solver()
		assert(s4.g_x[0] == 3)

		-- but the old state should be preserved in the previous frame.
		-- again, don't do this in real code.
		m2.sim:load(fp)
		g.y = 4
		local s5 = solver()
		assert(s5.g_x[0] == 2)

		-- branching again should clear the old state
		m2.sim:enter()
		local s6 = solver()
		assert(s6.g_x[0] == 4)
	end
end)
