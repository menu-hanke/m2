-- vim: ft=lua
local ffi = require "ffi"
local sim = require "sim"
local sim_env = require "sim_env"
local bg = require "buildgraph"
local bt = require "buildtype"
local v, m, any, none, ival = bg.v, bg.m, bg.any, bg.none, bg.ival
local fails = fails

local function envmaker(opt)
	return function(setup)
		return function()
			local sim = sim.create()
			local env = sim_env.create(sim)
			local mapper = bg.mapper(opt)
			env:inject_base()
			env:inject_fhk(mapper)
			debug.setfenv(setup, env.env)
			local run = setup()
			if run then
				sim:compile()
				run()
			end
		end
	end
end

local with_graph = envmaker {
	graph = {
		m("idx2a")                             + "x"        - "a",
		m("idx2d")                             + "x"        - "d",
		m("idxy2ab")                           + {"x", "y"} - {"a", "b"},
		m("idy2c")                             + "y"        - "c",
		m("idx2d_pos") %"x"^ival{0, math.huge} + "x"        - "x_unsat_cst",
		m("crash")                             + "x"        - "x_crash"
	},
	impl = {
		idx2a     = {lang="Lua", opt="models::id"},
		idx2d     = {lang="Lua", opt="models::id"},
		idxy2ab   = {lang="Lua", opt="models::id"},
		idy2c     = {lang="Lua", opt="models::id"},
		idx2d_pos = {lang="Lua", opt="models::id"},
		crash     = {lang="Lua", opt="models::crash"}
	}
}

test_remap_not_allowed = function()
	local mp = bg.mapper { graph = { m("malli") + "x" - "a" } }
	mp:data("x", ffi.NULL)
	assert(fails(function() mp:data("x", ffi.NULL) end))
end

test_map_global = with_graph(function()
	m2.globals.static { "x" }
	m2.expose(m2.globals)
	m2.G.x = 1234

	local solve_a = m2.solve("a"):from(m2.globals)

	return function()
		solve_a()
		assert(solve_a:res("a")[0] == 1234)
	end
end)

local function runtest_vec_xy(m2, V)
	m2.expose(V)

	local v = V:vec()
	v:alloc(3)
	local xs = v:newband("x")
	local ys = v:newband("y")

	xs[0] = 1; ys[0] = 100
	xs[1] = 2; ys[1] = 200
	xs[2] = 3; ys[2] = 300

	local solve_ab = m2.solve("a", "b"):from(V)

	return function()
		solve_ab(v)
		local ra = solve_ab:res("a")
		local rb = solve_ab:res("b")
		assert(ra[0] == 1 and ra[1] == 2 and ra[2] == 3)
		assert(rb[0] == 100 and rb[1] == 200 and rb[2] == 300)
	end
end

test_map_vec = with_graph(function()
	return runtest_vec_xy(m2, m2.obj(m2.component(bt.reals("x", "y", "z"))))
end)

test_map_vec_components = with_graph(function()
	return runtest_vec_xy(m2, m2.obj(
		m2.component(bt.reals("x")),
		m2.component(bt.reals("y"))
	))
end)

test_map_vec_vec_visibility = with_graph(function()
	local V1 = m2.expose(m2.obj(m2.component(bt.reals("x"))))
	local V2 = m2.expose(m2.obj(m2.component(bt.reals("y"))))

	local v1, v2 = V1:vec(), V2:vec()
	v1:alloc(1)
	v2:alloc(1)

	assert(fails(function() m2.solve("b"):from(V1):create_solver() end))
end)

test_map_vec_vec_with = with_graph(function()
	local V1 = m2.expose(m2.obj(m2.component(bt.reals("x"))))
	local V2 = m2.expose(m2.obj(m2.component(bt.reals("y"))))

	local v1, v2 = V1:vec(), V2:vec()
	v1:alloc(1)
	v2:alloc(1)

	v1:newband("x")[0] = 123
	v2:newband("y")[0] = 456

	local solve_ab = m2.solve("a", "b"):with(V2):from(V1)

	return function()
		m2.fhk.bind(V2, v2, 0)
		solve_ab(v1)
		assert(solve_ab:res("a")[0] == 123)
		assert(solve_ab:res("b")[0] == 456)
	end
end)

test_map_vec_globals_visibility = with_graph(function()
	local V = m2.expose(m2.obj(m2.component(bt.reals("x"))))
	m2.globals.static { "y" }
	m2.expose(m2.globals)

	local v = V:vec()
	v:alloc(1)
	v:newband("x")[0] = 123

	m2.G.y = 456

	local solve_ab = m2.solve("a", "b"):from(V)

	return function()
		solve_ab(v)
		assert(solve_ab:res("a")[0] == 123)
		assert(solve_ab:res("b")[0] == 456)
	end
end)

test_solver_error = with_graph(function()
	m2.globals.static { "x" }
	m2.expose(m2.globals)
	m2.G.x = -1234

	local solve_unsat = m2.solve("x_unsat_cst"):from(m2.globals)
	local solve_crash = m2.solve("x_crash"):from(m2.globals)

	return function()
		assert(fails(solve_unsat))
		assert(fails(solve_crash))
	end
end)

if ffi.C.HAVE_SOLVER_INTERRUPTS == 1 then

	test_map_virtual = with_graph(function()
		m2.fhk.virtual("x", m2.globals, function()
			return 3.14
		end)

		local solve_a = m2.solve("a"):from(m2.globals)

		return function()
			solve_a()
			assert(solve_a:res("a")[0] == 3.14)
		end
	end)

	test_map_virtual_comp = with_graph(function()
		local comp = m2.component(bt.reals("x"))
		local V = m2.expose(m2.obj(comp))

		local v = V:vec()
		v:alloc(3)
		local xs = v:newband("x")
		xs[0] = 1
		xs[1] = 2
		xs[2] = 3

		m2.fhk.virtual("y", comp, function(vec, idx)
			assert(vec == v)
			return vec:band("x")[idx] + 10
		end)

		local solve_c = m2.solve("c"):from(V)

		return function()
			solve_c(v)
			local cs = solve_c:res("c")
			assert(cs[0] == 11 and cs[1] == 12 and cs[2] == 13)
		end
	end)

	test_nested_virtuals = with_graph(function()
		m2.fhk.virtual("x", m2.globals, function()
			return 123
		end)

		local solve_d = m2.solve("d"):from(m2.globals)

		m2.fhk.virtual("y", m2.globals, function()
			solve_d()
			return solve_d:res("d")[0] * 2
		end)

		local solve_c = m2.solve("c"):from(m2.globals)

		return function()
			solve_c()
			assert(solve_c:res("c")[0] == 123*2)
		end
	end)

	test_map_lazy = with_graph(function()
		local comp = m2.component(bt.reals("x", "y"))

		local calls = 0
		comp:lazy("y", function(band, vs)
			vs:bandv("x"):mul(10, band)
			calls = calls + 1
		end)

		local V = m2.expose(m2.obj(comp))
		local vec = V:vec()

		vec:alloc(3)
		local x = vec:newband("x")
		x[0] = 7
		x[1] = 6
		x[2] = 5

		local solve_c = m2.solve("c"):from(V)

		return function()
			solve_c(vec)
			local c = solve_c:res("c")
			assert(c[0] == 70 and c[1] == 60 and c[2] == 50)
			assert(calls == 1)
		end
	end)

end
