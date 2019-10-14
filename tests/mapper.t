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
			sim:compile()
			run()
		end
	end
end

local function maketype(name, vs)
	local t = typing.newtype(name)
	for f,v in pairs(vs) do t.vars[f] = typing.builtin_types[v] end
	return t
end

local with_graph = envmaker {
	graph = {
		m("idx2a")                             + "x"        - "a",
		m("idxy2ab")                           + {"x", "y"} - {"a", "b"},
		m("idy2c")                             + "y"        - "c",
		m("idx2d_pos") %"x"^ival{0, math.huge} + "x"        - "x_unsat_cst",
		m("crash")                             + "x"        - "x_crash"
	},
	impl = {
		idx2a     = {lang="Lua", opt="models::id"},
		idxy2ab   = {lang="Lua", opt="models::id"},
		idy2c     = {lang="Lua", opt="models::id"},
		idx2d_pos = {lang="Lua", opt="models::id"},
		crash     = {lang="Lua", opt="models::crash"}
	}
}

local function is_computed(x)
	return x.resolve == ffi.NULL and x.supp == ffi.NULL
end

test_map_nothing = function()
	local mp = bg.mapper { graph = { m("malli") + "x" - "a" } }
	mp:bind_computed()
	assert(is_computed(mp.vars.x.mapping))
	assert(is_computed(mp.vars.a.mapping))
end

test_remap_not_allowed = function()
	local mp = bg.mapper { graph = { m("malli") + "x" - "a" } }
	mp:data("x", ffi.NULL)
	assert(fails(function() mp:data("x", ffi.NULL) end))
end

test_map_global = with_graph(function()
	globals.static { "x" }
	fhk.expose(globals)
	G.x = 1234

	local solve_a = fhk.solve("a"):from(globals)

	return function()
		solve_a()
		assert(solve_a:res("a")[0] == 1234)
	end
end)

test_map_vec = with_graph(function()
	local Vtest = obj("Vtest", maketype("vtest", {
		x = "real",
		y = "real",
		z = "real"
	}))
	fhk.expose(Vtest)

	local v = Vtest:vec()
	v:alloc(3)
	local xs = v:band("x")
	local ys = v:band("y")

	xs[0] = 1; ys[0] = 100
	xs[1] = 2; ys[1] = 200
	xs[2] = 3; ys[2] = 300

	local solve_ab = fhk.solve("a", "b"):from(Vtest)

	return function()
		solve_ab(v)
		local ra = solve_ab:res("a")
		local rb = solve_ab:res("b")
		assert(ra[0] == 1 and ra[1] == 2 and ra[2] == 3)
		assert(rb[0] == 100 and rb[1] == 200 and rb[2] == 300)
	end
end)

test_solver_errors = with_graph(function()
	globals.static { "x" }
	fhk.expose(globals)
	G.x = -1234

	local solve_unsat = fhk.solve("x_unsat_cst"):from(globals)
	local solve_crash = fhk.solve("x_crash"):from(globals)

	return function()
		assert(fails(solve_unsat))
		assert(fails(solve_crash))
	end
end)

if ffi.C.HAVE_SOLVER_INTERRUPTS == 1 then

	test_map_virtual = with_graph(function()
		fhk.virtual("x", globals, function()
			return 3.14
		end)

		local solve_a = fhk.solve("a"):from(globals)

		return function()
			solve_a()
			assert(solve_a:res("a")[0] == 3.14)
		end
	end)

	test_map_virtual_vec = with_graph(function()
		local V = obj("V", maketype("v", {
			x = "real",
		}))

		local v = V:vec()
		v:alloc(3)
		local xs = v:band("x")
		xs[0] = 1
		xs[1] = 2
		xs[2] = 3

		fhk.expose(V)
		fhk.virtual("y", V, function(idx)
			return v:band("x")[idx] + 10
		end)

		local solve_c = fhk.solve("c"):from(V)

		return function()
			solve_c(v)
			local cs = solve_c:res("c")
			assert(cs[0] == 11 and cs[1] == 12 and cs[2] == 13)
		end
	end)

end
