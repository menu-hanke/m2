-- vim: ft=lua
local ffi = require "ffi"
local sim = require "sim"
local sim_env = require "sim_env"
local typing = require "typing"
local bg = require "buildgraph"
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
		m("crash")                             + "x"        - "x_crash",
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

local with_prefix_graph = envmaker {
	graph = {
		m("x->a") + "pf#x" - "pf#a"
	},
	impl = {
		["x->a"] = {lang="Lua", opt="models::id"}
	}
}

test_map_write = with_graph(function()
	local solve_ab = m2.solve("a", "b"):given("x", "y")

	return function()
		solve_ab.x = 1
		solve_ab.y = 2
		solve_ab()
		assert(solve_ab.a == 1)
		assert(solve_ab.b == 2)
	end
end)

test_remap = with_graph(function()
	local ns1 = m2.data.static(m2.fhk.typeof { "x" })
	local ns2 = m2.data.static(m2.fhk.typeof { "x" })

	m2.solve("a"):given(ns1):create_solver()
	m2.solve("a"):given(ns2):create_solver()
	assert(fails(function()
		m2.solve("a")
			:given(ns1)
			:given(ns2)
			:create_solver()
	end))
end)

test_overwrite_given = with_graph(function()
	local ns = m2.data.static(m2.fhk.typeof { "x" })
	assert(fails(function()
		m2.solve("x")
			:given(ns)
			:create_solver()
	end))
end)

test_map_ns = with_graph(function()
	local ns1, G1 = m2.data.static(m2.fhk.typeof { "x" })
	local ns2, G2 = m2.data.static(m2.fhk.typeof { "x" })
	G1.x = 1234
	G2.x = 5678

	local solve_a1 = m2.solve("a"):given(ns1)
	local solve_a2 = m2.solve("a"):given(ns2)

	return function()
		solve_a1()
		solve_a2()

		assert(solve_a1.a == 1234)
		assert(solve_a2.a == 5678)
	end
end)

test_map_always_given = with_graph(function()
	local globals, G = m2.data.static(m2.fhk.typeof { "x" })
	local locals, L = m2.data.static(m2.fhk.typeof { "y" })
	G.x = 111
	L.y = 222

	m2.fhk.config(globals, {global=true})
	local solve_ab = m2.solve("a", "b"):given(locals)

	return function()
		solve_ab()
		assert(solve_ab.a == 111)
		assert(solve_ab.b == 222)
	end
end)

test_map_prefix = with_prefix_graph(function()
	local prefix = m2.fhk.prefix("pf")
	local ns, G = m2.data.static(m2.fhk.typeof(prefix { "x" }))
	m2.fhk.config(ns, {rename=prefix})

	local solve_a = m2.solve(prefix{"a"}):given(ns)

	return function()
		G.x = 5
		solve_a()
		assert(solve_a.a == 5)
	end
end)

test_map_vec = with_graph(function()
	local V = m2.soa.new(typing.reals("x", "y", "z"))
	local v = V()
	m2.soa.alloc(v, 3)
	local xs = m2.soa.newband(v, "x")
	local ys = m2.soa.newband(v, "y")

	xs[0] = 1; ys[0] = 100
	xs[1] = 2; ys[1] = 200
	xs[2] = 3; ys[2] = 300

	local solve_ab = m2.solve("a", "b"):over(V)

	return function()
		solve_ab(v)
		local ra = solve_ab.a
		local rb = solve_ab.b
		assert(ra[0] == 1 and ra[1] == 2 and ra[2] == 3)
		assert(rb[0] == 100 and rb[1] == 200 and rb[2] == 300)
	end
end)

test_map_vec_vec_visibility = with_graph(function()
	local V1 = m2.soa.new(typing.reals("x"))
	local V2 = m2.soa.new(typing.reals("y"))

	local v1, v2 = V1(), V2()
	m2.soa.alloc(v1, 1)
	m2.soa.alloc(v2, 1)

	assert(fails(function()
		m2.solve("b")
			:over(V1)
			:create_solver()
	end))
end)

test_map_vec_vec = with_graph(function()
	local V1 = m2.soa.new(typing.reals("x"))
	local V2 = m2.soa.new(typing.reals("y"))

	local v1, v2 = V1(), V2()
	m2.soa.alloc(v1, 2)
	m2.soa.alloc(v2, 2)

	local x = m2.soa.newband(v1, "x")
	local y = m2.soa.newband(v2, "y")

	x[0] = 123; x[1] = 456
	y[0] = 789; y[1] = 000

	local solve_ab_nofollow = m2.solve("a", "b")
		:given(V2)
		:over(V1)
	
	local solve_ab_follow = m2.solve("a", "b")
		:given(V2, {follow=true, bind=v2})
		:over(V1)

	return function()
		m2.fhk.bind(solve_ab_nofollow, V2, v2, 0)
		solve_ab_nofollow(v1)
		
		local a = solve_ab_nofollow.a
		local b = solve_ab_nofollow.b
		assert(a[0] == 123 and a[1] == 456)
		assert(b[0] == 789 and b[1] == 789)

		solve_ab_follow(v1)
		a = solve_ab_follow.a
		b = solve_ab_follow.b
		assert(a[0] == 123 and a[1] == 456)
		assert(b[0] == 789 and b[1] == 000)
	end
end)

test_map_vec_globals_visibility = with_graph(function()
	local V = m2.soa.new(typing.reals("x"))

	local v = V()
	m2.soa.alloc(v, 1)
	m2.soa.newband(v, "x")[0] = 123

	local ns, G = m2.data.static(typing.reals("y"))
	G.y = 456

	local solve_ab = m2.solve("a", "b")
		:given(ns)
		:over(V)

	return function()
		solve_ab(v)
		assert(solve_ab.a[0] == 123)
		assert(solve_ab.b[0] == 456)
	end
end)

test_solver_vec_alloc = with_graph(function()
	local V = m2.soa.new(typing.reals("x"))
	local v = V()

	-- big alloc because we want to detect possible allocation problems
	local N = 1234
	m2.soa.alloc(v, N)
	local x = m2.soa.newband(v, "x")

	local solve_a = m2.solve("a"):over(V)

	return function()
		for i=0, N-1 do x[i] = i end
		solve_a(v, #v)
		local res1 = solve_a.a

		for i=0, N-1 do x[i] = 2*i end
		solve_a(v)
		local res2 = solve_a.a

		for i=0, N-1 do x[i] = 3*i end
		local buf = ffi.new("vreal[?]", N)
		solve_a(v, {buf})
		local res3 = solve_a.a

		assert(res3 == buf)
		for i=0, N-1 do
			assert(res1[i] == i)
			assert(res2[i] == 2*i)
			assert(res3[i] == 3*i)
		end
	end
end)

test_solver_error = with_graph(function()
	local ns, G = m2.data.static(typing.reals("x"))
	G.x = -1234

	local solve_unsat = m2.solve("x_unsat_cst"):given(ns)
	local solve_crash = m2.solve("x_crash"):given(ns)

	return function()
		assert(fails(solve_unsat))
		assert(fails(solve_crash))
	end
end)

test_create_solver1_result_gc = with_graph(function()
	local t = {}
	for i=1, 1000 do t[i] = ffi.new("float[?]", 1000) end

	local ns, G = m2.data.static(typing.reals("x"))
	local solve_a = m2.solve("a"):given(ns)
	G.x = 1234

	return function()
		solve_a()
		assert(solve_a.a == 1234)

		-- https://stackoverflow.com/questions/28320213/why-do-we-need-to-call-luas-collectgarbage-twice
		collectgarbage()
		collectgarbage()

		-- if results are gced, this should overwrite with zeros
		t = {}
		for i=1, 1000 do t[i] = ffi.new("float[?]", 1000) end

		assert(solve_a.a == 1234)
	end
end)

if ffi.C.fhkG_have_interrupts() then

	test_map_virtual = with_graph(function()
		local vs = m2.virtuals()
		vs.virtual("x", function()
			return 3.14
		end)

		local solve_a = m2.solve("a"):given(vs)

		return function()
			solve_a()
			assert(solve_a.a == 3.14)
		end
	end)

	test_map_virtual_vec = with_graph(function()
		local V = m2.soa.new(typing.reals("x"))

		local v = V()
		m2.soa.alloc(v, 3)
		local xs = m2.soa.newband(v, "x")
		xs[0] = 1
		xs[1] = 2
		xs[2] = 3

		local vs = m2.virtuals()
		vs.virtual("y", function(solver)
			local vec, idx = V:solver_pos(solver)
			assert(vec == v)
			return vec.x[idx] + 10
		end)

		local solve_c = m2.solve("c")
			:given(vs)
			:over(V)

		return function()
			solve_c(v)
			local cs = solve_c.c
			assert(cs[0] == 11 and cs[1] == 12 and cs[2] == 13)
		end
	end)

	test_nested_virtuals = with_graph(function()
		local vs1 = m2.virtuals()
		vs1.virtual("x", function()
			return 123
		end)

		local solve_d = m2.solve("d"):given(vs1)

		local vs2 = m2.virtuals()
		vs2.virtual("y", function()
			solve_d()
			return solve_d.d * 2
		end)

		local solve_c = m2.solve("c"):given(vs2)

		return function()
			solve_c()
			assert(solve_c.c == 123*2)
		end
	end)

end
