-- vim: ft=lua
local ffi = require "ffi"
local sim = require "sim"
local sim_env = require "sim_env"
local typing = require "typing"
local misc = require "misc"
local T = require "testgraph"
local fails = fails

local function t(f)
	return function()
		local sim = sim.create()
		local env = sim_env.create(sim)
		env:inject_base()

		local testenv = T.injector(misc.delegate(env, env.inject_fhk))
		testenv(env.env)
		setfenv(f, env.env)

		if f() == false then return end
		sim:compile()
		sim:event("test")
	end
end

test_solver_direct = t(function()
	graph {
		m("x->x'", "Lua::models::id"),
		m("y->y'", "Lua::models::id"),
		h{["x"]="real",  ["y"]="real"},
		h{["x'"]="real", ["y'"]="real"}
	}

	local solve_xy = m2.fhk.solve("x'", "y'"):given("x", "y")

	m2.on("test", function()
		solve_xy.x = 1
		solve_xy.y = 2
		solve_xy()
		assert(solve_xy["x'"] == 1)
		assert(solve_xy["y'"] == 2)
	end)
end)

test_constraint_fail = t(function()
	graph {
		m("x->x'", "Lua::models::id"):check{x=between(0, math.huge)},
		h{x="real", ["x'"]="real"}
	}

	local solver = m2.fhk.solve("x'"):given("x")

	m2.on("test", function()
		solver.x = -1
		assert(fails(solver))
	end)
end)

test_model_crash = t(function()
	graph {
		m("x->x'", "Lua::models::crash"),
		h{x="real", ["x'"]="real"}
	}

	local solver = m2.fhk.solve("x'"):given("x")

	m2.on("test", function()
		assert(fails(solver))
	end)
end)

test_context = t(function()
	graph {
		m("x->x'", "Lua::models::id"),
		h{x="real", ["x'"]="real"}
	}
	
	local ctx = m2.fhk.context():given("x")
	local solve_x = m2.fhk.solve("x'"):given(ctx)

	m2.on("test", function()
		solve_x.x = 100
		solve_x()
		assert(solve_x["x'"] == 100)
	end)
end)

test_inspect_plan = t(function()
	graph {
		m("x->y", "Lua::models::id"),
		m("y->z", "Lua::models::id"),
		m("u->v", "Lua::models::id"),
		h{x="real", y="real", z="real"}
	}

	local col = m2.fhk.collect(true, true)
	m2.fhk.solve("z"):given("x"):hook(col)
	m2.fhk.select_subgraphs()

	assert(col.vars.x.given and (not col.vars.x.computed) and (not col.vars.x.target))
	assert((not col.vars.y.given) and col.vars.y.computed and (not col.vars.y.target))
	assert((not col.vars.z.given) and col.vars.z.computed and col.vars.z.target)
	assert(not col.vars.u)
	assert(not col.vars.v)
	assert(col.models["x->y"])
	assert(col.models["y->z"])
	assert(not col.models["u->v"])
end)

test_allow_solver_after_subgraph = t(function()
	graph {
		m("x->x'", "Lua::models::id"),
		h{x="real", ["x'"]="real"}
	}

	m2.fhk.solve("x'"):given("x")
	m2.fhk.select_subgraphs()
	m2.fhk.solve("x'"):given("x")
end)

test_solve_invalid_var = t(function()
	graph {
		m("x->x'", "Lua::models::id"),
		h{x="real", ["x'"]="real"}
	}

	m2.fhk.solve("y"):given("x")
	assert(fails(m2.fhk.select_subgraphs))
	return false
end)

test_infer_tvalue = t(function()
	graph {
		m("x,y,z->x',y',z'", "Lua::models::id"),
		h{["x'"]="real", ["y'"]="real", ["z'"]="real"}
	}

	local data = m2.data.static {
		x = "real",
		y = "mask",
		z = "u32"
	}

	m2.fhk.solve("x'", "y'", "z'"):given(data)
end)

test_infer_ctype = t(function()
	graph {
		m("x,y,z->x',y',z'", "Lua::models::id"),
		h{["x'"]="real", ["y'"]="mask", ["z'"]="id"}
	}

	local data, D = m2.data.static {
		x = "double",
		y = ffi.typeof("uint64_t"),
		z = "uint64_t"
	}

	-- this hint should cause y to be inferred as mask
	local cls = m2.class { a = 2 }
	m2.fhk.class("y", cls)

	local solver = m2.fhk.solve("x'", "y'", "z'"):given(data)

	m2.on("test", function()
		D.x = 1
		D.y = cls.a
		D.z = 3
		solver()
		assert(type(solver["x'"]) == "number" and solver["x'"] == 1)
		assert(type(solver["y'"]) == "cdata" and solver["y'"] == cls.a)
		assert(type(solver["z'"]) == "cdata" and solver["z'"] == 3)
	end)
end)

test_float_tvalue = t(function()
	graph {
		m("x->x'", "Lua::models::id"),
		h{["x'"]="real"}
	}

	local data, D = m2.data.static { x = "float" }
	local solver = m2.fhk.solve("x'"):given(data)

	m2.on("test", function()
		D.x = 1234.5 -- this is exactly representable so it's ok to compare
		solver()
		assert(solver["x'"] == 1234.5)
	end)
end)

test_incompatible_hint = t(function()
	graph { h{x="real"} }
	assert(fails(function() m2.fhk.type("x", "mask") end))
end)

test_incompatible_map = t(function()
	graph {
		m("x->x'", "Lua::models::id"),
		h{x="real", ["x'"]="real"}
	}

	local data = m2.data.static { x = "uint64_t" }
	m2.fhk.solve("x'"):given(data)
	assert(fails(function() m2.sim:compile() end))
	return false
end)

test_remap_fails = t(function()
	graph {
		m("x->x'", "Lua::models::id"),
		h{x="real", ["x'"]="real"}
	}

	local data1 = m2.data.static { x = "real" }
	local data2 = m2.data.static { x = "real" }
	m2.fhk.solve("x'"):given(data1):given(data2)
	assert(fails(function() m2.sim:compile() end))
	return false
end)

test_remap_direct_fails = t(function()
	graph {
		m("x->x'", "Lua::models::id"),
		h{x="real", ["x'"]="real"}
	}

	local data = m2.data.static { x = "real" }
	m2.fhk.solve("x'"):given("x"):given(data)
	assert(fails(function() m2.sim:compile() end))
	return false
end)

test_map_name_mangling = t(function()
	graph {
		m("prefix#x->prefix#x'", "Lua::models::id"),
		h{["prefix#x"]="real", ["prefix#x'"]="real"}
	}

	local data = m2.data.static { x = "real" }

	m2.fhk.solve("prefix#x'"):given(function(name)
		return data:fhk_map(name:match("prefix#([%w%']+)"))
	end)
end)

test_map_vec = t(function()
	graph {
		m("x,y->x',y'", "Lua::models::id"),
		h{["x'"]="real", ["y'"]="real"}
	}

	local V = m2.soa.new(m2.type { x = "real", y = "real", z = "real" })
	local v = V()
	m2.soa.alloc(v, 3)

	local xs = m2.soa.newband(v, "x")
	local ys = m2.soa.newband(v, "y")
 	xs[0] = 1; ys[0] = 100
 	xs[1] = 2; ys[1] = 200
 	xs[2] = 3; ys[2] = 300

	local solver = m2.fhk.solve("x'", "y'"):given(V):over(V)

	m2.on("test", function()
		solver(v)
		local x = solver["x'"]
		local y = solver["y'"]
		assert(x[0] == 1 and x[1] == 2 and x[2] == 3)
		assert(y[0] == 100 and y[1] == 200 and y[2] == 300)
	end)
end)

test_map_vec_follow = t(function()
	graph {
		m("x,y->x',y'", "Lua::models::id"),
		h{["x'"]="real", ["y'"]="real"}
	}

	local V1 = m2.soa.new(m2.type { x = "real" })
	local V2 = m2.soa.new(m2.type { y = "real" })

	local v1, v2 = V1(), V2()
	m2.soa.alloc(v1, 2)
	m2.soa.alloc(v2, 2)

 	local x = m2.soa.newband(v1, "x")
 	local y = m2.soa.newband(v2, "y")
 
 	x[0] = 123; x[1] = 456
 	y[0] = 789; y[1] = 000

	local solver_follow = m2.fhk.solve("x'", "y'")
		:given(V1)
		:given(V2)
		:over(V1)
	
	m2.on("test", function()
		V2:fhk_bind(solver_follow, v2)
		solver_follow(v1)
		local xs = solver_follow["x'"]
		local ys = solver_follow["y'"]
		assert(xs[0] == 123 and xs[1] == 456)
		assert(ys[0] == 789 and ys[1] == 000)
	end)
	
	local solver_nofollow = m2.fhk.solve("x'", "y'")
		:given(V1)
		:given(V2:fhk_mapper("static"))
		:over(V1)
	
	m2.on("test", function()
		V2:fhk_bind(solver_nofollow, v2, 0)
		solver_nofollow(v1)
		local xs = solver_nofollow["x'"]
		local ys = solver_nofollow["y'"]
		assert(xs[0] == 123 and xs[1] == 456)
		assert(ys[0] == 789 and ys[1] == 789)
	end)
end)

test_map_mixed = t(function()
	graph {
		m("x,y->x',y'", "Lua::models::id"),
		h{["x'"]="real", ["y'"]="real"}
	}

	local V = m2.soa.new(m2.type { x = "real" })
	local v = V()
	m2.soa.alloc(v, 1)
	m2.soa.newband(v, "x")[0] = 123

	local ns, G = m2.data.static(m2.type { y = "real" })
	G.y = 456

	local solver = m2.fhk.solve("x'", "y'")
		:given(V)
		:given(ns)
		:over(V)
	
	m2.on("test", function()
		solver(v)
		assert(solver["x'"][0] == 123)
		assert(solver["y'"][0] == 456)
	end)
end)

test_solver_vec_alloc = t(function()
	graph {
		m("x->x'", "Lua::models::id"),
		h{["x'"]="real"}
	}

 	local V = m2.soa.new(m2.type { x = "real" })
 	local v = V()
 
 	-- big alloc because we want to detect possible allocation problems
 	local N = 1234
 	m2.soa.alloc(v, N)
 	local x = m2.soa.newband(v, "x")
 
 	local solver = m2.fhk.solve("x'"):given(V):over(V)
 
	m2.on("test", function()
 		for i=0, N-1 do x[i] = i end
 		solver(v, #v)
 		local res1 = solver["x'"]
 
 		for i=0, N-1 do x[i] = 2*i end
 		solver(v)
 		local res2 = solver["x'"]
 
 		for i=0, N-1 do x[i] = 3*i end
 		local buf = ffi.new("vreal[?]", N)
 		solver(v, {buf})
 		local res3 = solver["x'"]
 
 		assert(res3 == buf)
 		for i=0, N-1 do
 			assert(res1[i] == i)
 			assert(res2[i] == 2*i)
 			assert(res3[i] == 3*i)
 		end
 	end)
end)

test_solver_result_gc = t(function()
	graph {
		m("x->x'", "Lua::models::id"),
		h{["x'"]="real"}
	}

 	local t = {}
 	for i=1, 1000 do t[i] = ffi.new("float[?]", 1000) end
 
 	local ns, G = m2.data.static(m2.type { x = "real" })
 	local solver = m2.fhk.solve("x'"):given(ns)
 	G.x = 1234
 
 	return function()
 		solver()
 		assert(solver["x'"] == 1234)
 
 		-- https://stackoverflow.com/questions/28320213/why-do-we-need-to-call-luas-collectgarbage-twice
 		collectgarbage()
 		collectgarbage()
 
 		-- if results are gced, this should overwrite with zeros
 		t = {}
 		for i=1, 1000 do t[i] = ffi.new("float[?]", 1000) end
 
 		assert(solver["x'"] == 1234)
 	end
end)

if ffi.C.fhkG_have_interrupts() then

	test_map_virtual = t(function()
		graph {
			m("x->x'", "Lua::models::id"),
			h{["x'"]="real"}
		}

		local vs = m2.fhk.virtuals()

 		vs:virtual("x", function()
 			return 3.14
 		end, "real")
 
 		local solver = m2.fhk.solve("x'"):given(vs)
 
		m2.on("test", function()
 			solver()
 			assert(solver["x'"] == 3.14)
 		end)
 	end)

 	test_map_virtual_vec = t(function()
		graph {
			m("x->x'", "Lua::models::id"),
			h{["x'"]="real"}
		}

 		local V = m2.soa.new(m2.type { z = "real" })
 
 		local v = V()
 		m2.soa.alloc(v, 3)
 		local xs = m2.soa.newband(v, "z")
 		xs[0] = 1
 		xs[1] = 2
 		xs[2] = 3
 
 		local vs = m2.fhk.virtuals()

 		vs:virtual("x", function(solver)
 			local vec, idx = V:fhk_solver_ptr(solver)
 			assert(vec == v)
 			return vec.z[idx] + 10
 		end, "real")
 
 		local solver = m2.fhk.solve("x'"):given(vs):over(V)
 
		m2.on("test", function()
 			solver(v)
 			local x = solver["x'"]
 			assert(x[0] == 11 and x[1] == 12 and x[2] == 13)
 		end)
 	end)

 	test_nested_virtuals = t(function()
		graph {
			m("x->x'", "Lua::models::id"),
			m("y->y'", "Lua::models::id"),
			h{["x'"]="real", ["y'"]="real"}
		}

 		local vs1 = m2.fhk.virtuals()
 		vs1:virtual("x", function()
 			return 123
 		end, "real")
 
 		local solve_x = m2.fhk.solve("x'"):given(vs1)
 
 		local vs2 = m2.fhk.virtuals()
 		vs2:virtual("y", function()
 			solve_x()
 			return solve_x["x'"] * 2
 		end, "real")
 
 		local solve_y = m2.fhk.solve("y'"):given(vs2)
 
		m2.on("test", function()
 			solve_y()
 			assert(solve_y["y'"] == 123*2)
 		end)
 	end)

end
