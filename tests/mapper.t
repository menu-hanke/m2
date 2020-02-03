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

test_remap = with_graph(function()
	local ns1 = m2.ns.static { "x" }
	local ns2 = m2.ns.static { "x" }

	m2.solve("a"):from(ns1):create_solver()
	m2.solve("a"):from(ns2):create_solver()
	assert(fails(function() m2.solve("a"):with(ns1):from(ns2):create_solver() end))
end)

test_overwrite_given = with_graph(function()
	local ns = m2.ns.static { "x" }
	assert(fails(function() m2.solve("x"):from(ns):create_solver() end))
end)

test_map_ns = with_graph(function()
	local ns1, G1 = m2.ns.static { "x" }
	local ns2, G2 = m2.ns.static { "x" }
	G1.x = 1234
	G2.x = 5678

	local solve_a1 = m2.solve("a"):from(ns1)
	local solve_a2 = m2.solve("a"):from(ns2)

	return function()
		solve_a1()
		solve_a2()

		assert(solve_a1:res("a")[0] == 1234)
		assert(solve_a2:res("a")[0] == 5678)
	end
end)

test_map_always_visible = with_graph(function()
	local globals, G = m2.ns.static { "x" }
	local locals, L = m2.ns.static { "y" }
	G.x = 111
	L.y = 222

	m2.fhk.global(globals)
	local solve_ab = m2.solve("a", "b"):from(locals)

	return function()
		solve_ab()
		assert(solve_ab:res("a")[0] == 111)
		assert(solve_ab:res("b")[0] == 222)
	end
end)

test_map_vec = with_graph(function()
	local V = m2.obj(bt.reals("x", "y", "z"))
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
end)

test_map_vec_vec_visibility = with_graph(function()
	local V1 = m2.obj(bt.reals("x"))
	local V2 = m2.obj(bt.reals("y"))

	local v1, v2 = V1:vec(), V2:vec()
	v1:alloc(1)
	v2:alloc(1)

	assert(fails(function() m2.solve("b"):from(V1):create_solver() end))
end)

test_map_vec_vec_with = with_graph(function()
	local V1 = m2.obj(bt.reals("x"))
	local V2 = m2.obj(bt.reals("y"))

	local v1, v2 = V1:vec(), V2:vec()
	v1:alloc(1)
	v2:alloc(1)

	v1:newband("x")[0] = 123
	v2:newband("y")[0] = 456

	local solve_ab = m2.solve("a", "b"):with(V2):from(V1)

	return function()
		solve_ab:bind(V2, v2, 0)
		solve_ab(v1)
		assert(solve_ab:res("a")[0] == 123)
		assert(solve_ab:res("b")[0] == 456)
	end
end)

test_map_vec_globals_visibility = with_graph(function()
	local V = m2.obj(bt.reals("x"))

	local v = V:vec()
	v:alloc(1)
	v:newband("x")[0] = 123

	local ns, G = m2.ns.static { "y" }
	G.y = 456

	local solve_ab = m2.solve("a", "b"):with(ns):from(V)

	return function()
		solve_ab(v)
		assert(solve_ab:res("a")[0] == 123)
		assert(solve_ab:res("b")[0] == 456)
	end
end)

test_solver_vec_alloc = with_graph(function()
	local V = m2.obj(bt.reals("x"))
	local v = V:vec()

	-- big alloc because we want to detect possible allocation problems
	local N = 1234
	v:alloc(N)
	local x = v:newband("x")

	local solve_a = m2.solve("a"):from(V)

	return function()
		for i=0, N-1 do x[i] = i end
		solve_a(v, v:len())
		local res1 = solve_a:res("a")

		for i=0, N-1 do x[i] = 2*i end
		solve_a(v)
		local res2 = solve_a:res("a")

		for i=0, N-1 do x[i] = 3*i end
		local buf = ffi.new("vreal[?]", N)
		solve_a(v, {buf})
		local res3 = solve_a:res("a")

		assert(res3 == buf)
		for i=0, N-1 do
			assert(res1[i] == i)
			assert(res2[i] == 2*i)
			assert(res3[i] == 3*i)
		end
	end
end)

test_solver_error = with_graph(function()
	local ns, G = m2.ns.static { "x" }
	G.x = -1234

	local solve_unsat = m2.solve("x_unsat_cst"):from(ns)
	local solve_crash = m2.solve("x_crash"):from(ns)

	return function()
		assert(fails(solve_unsat))
		assert(fails(solve_crash))
	end
end)

test_create_solver1_result_gc = with_graph(function()
	local t = {}
	for i=1, 1000 do t[i] = ffi.new("float[?]", 1000) end

	local ns, G = m2.ns.static { "x" }
	local solve_a = m2.solve("a"):from(ns)
	G.x = 1234

	return function()
		solve_a()
		assert(solve_a:res("a")[0] == 1234)

		-- https://stackoverflow.com/questions/28320213/why-do-we-need-to-call-luas-collectgarbage-twice
		collectgarbage()
		collectgarbage()

		-- if results are gced, this should overwrite with zeros
		t = {}
		for i=1, 1000 do t[i] = ffi.new("float[?]", 1000) end

		assert(solve_a:res("a")[0] == 1234)
	end
end)

if ffi.C.HAVE_SOLVER_INTERRUPTS == 1 then

	test_map_virtual = with_graph(function()
		local vs = m2.virtuals()
		vs.virtual("x", function()
			return 3.14
		end)

		local solve_a = m2.solve("a"):from(vs)

		return function()
			solve_a()
			assert(solve_a:res("a")[0] == 3.14)
		end
	end)

	test_map_virtual_vec = with_graph(function()
		local V = m2.obj(bt.reals("x"))

		local v = V:vec()
		v:alloc(3)
		local xs = v:newband("x")
		xs[0] = 1
		xs[1] = 2
		xs[2] = 3

		local vs = m2.virtuals(V)
		vs.virtual("y", function(vec, idx)
			assert(vec == v)
			return vec:band("x")[idx] + 10
		end)

		local solve_c = m2.solve("c"):with(vs):from(V)

		return function()
			solve_c(v)
			local cs = solve_c:res("c")
			assert(cs[0] == 11 and cs[1] == 12 and cs[2] == 13)
		end
	end)

	test_nested_virtuals = with_graph(function()
		local vs1 = m2.virtuals()
		vs1.virtual("x", function()
			return 123
		end)

		local solve_d = m2.solve("d"):from(vs1)

		local vs2 = m2.virtuals()
		vs2.virtual("y", function()
			solve_d()
			return solve_d:res("d")[0] * 2
		end)

		local solve_c = m2.solve("c"):from(vs2)

		return function()
			solve_c()
			assert(solve_c:res("c")[0] == 123*2)
		end
	end)

end
