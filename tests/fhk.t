-- vim: ft=lua
local ffi = require "ffi"
local _ = require "testgraph"

-- identity : X^n -> X^n
local function id(...) return ... end

-- n-dimension dot product : X^n -> X^1
local function dot(...)
	local xs = {...}
	local d = 0

	for i,x in ipairs(xs[1]) do
		for j=2, #xs do
			x = x * xs[j][i]
		end
		d = d + x
	end

	return {d}
end

local function cf(...)
	local r = {...}
	return function() return unpack(r) end
end

test_solver_single = _(function()
	graph {
		m { "a -> x", id }
	}

	given { a = {123} }
	solution { x = {123} }
end)

test_solver_cost = _(function()
	graph {
		m { "-> x %1", cf {2}, k=2},
		m { "-> x %2", cf {1}, k=1}
	}

	solution { x = {1} }
end)

test_solver_given_check = _(function()
	graph {
		m { "-> x [a>=0+10]", cf {1} },
		m { "-> x [a<=0+10]", cf {2} }
	}

	given { a = {1} }
	solution { x = {1} }

	given { a = {-1} }
	solution { x = {2} }
end)

test_solver_computed_check = _(function()
	graph {
	 	m { "-> x", cf {1} },
		m { "-> y %k100", cf {1}, k=100},
		m { "-> y [x<=0+1000] %k1", cf {2}, k=1}
	}

	solution { y = {1} }
end)

test_solver_complex_parameter = _(function()
	graph {
		u { "even",
			ufunc(cf { 0, 2 }, "k"),
			ufunc(function(inst) return (inst%2==0) and {0} or {} end, "i")
		},
		m { "g# a:even -> g#x", dot }
	}

	given { a = {1, 2, 3, 4} }
	solution { ["g#x"] = {1+3} }
end)

test_solver_chain = _(function()
	graph {
		m { "a -> x", id },
		m { "x -> y", id }
	}

	given { a = {123} }
	solution { x = {123} }
end)

test_solver_set = _(function()
	graph {
		m { "g# a:@space -> g#x", dot }
	}

	given { a = {1, 2, 3} }
	solution { ["g#x"] = {1+2+3} }
end)

test_solver_set_chain = _(function()
	graph {
		m { "default# a -> x", id },
		m { "g# x:@space -> g#y", dot },
	}

	given { a = {1, 2, 3} }
	solution { ["g#y"] = {1+2+3} }
end)

test_solver_ret_space = _(function()
	graph {
		m { "-> x:@space", cf {1, 2, 3} }
	}

	solution { x = {1, 2, 3} }
end)

test_solver_retbuf = _(function()
	graph {
		m { "a,b -> z,w", id, k=1 },
		m { "c,d -> z,w", id, k=2 }
	}

	given { a = {1, 2, 3}, b = {4, 5, 6} }
	solution { z = {1, 2, 3}, w = {4, 5, 6} }
end)

test_solver_offset_collect = _(function()
	graph {
		m { "a -> x", id },
	}

	given { a = {1, 2, 3} }
	solution { x = {na, 2, 3} }
end)

test_solver_modcall_emptyset = _(function()
	graph {
		m { "g# a:@space -> g#x", cf{1} }
	}

	given { a = {} }
	solution { ["g#x"] = {1} }
end)

test_solver_bound_retry = _(function()
	graph {
		m { "x->a",  1, k=1, c=1},
		m { "y->a",  2, k=2, c=2},
		m { "xp->x [xp>=0+100] [xq>=0+200]", 3  },
		m { "yp->y [yp>=0+100] [yq>=0+200]", 4  },
		m { "->xp",  -1 },
		m { "->xq",  1  },
		m { "->yp",  1  },
		m { "->yq",  -1 }
	}

	-- solve a
	--     try x->a
	--         solve x
	--             try xp->x
	--                 solve xp
	--                     try ->xp
	--                     xp = -1
	--                 beta bound
	--             beta bound
	--         beta bound
	--     beta bound
	--     try y->a
	--         solve y
	--             try yp->y
	--                 solve yp
	--                     try ->yp
	--                     yp = 1
	--                 solve yq
	--                     try ->yq
	--                     yq = -1
	--                 beta bound
	--             beta bound
	--         beta bound
	--     beta bound
	--     try x->a
	--         solve x
	--             try xp->x
	--                 solve xq
	--                     xq = 1
	--              x = 3
	--     a = 1

	solution { a = {1} }
end)

test_solver_set_given_constraint = _(function()
	graph {
		m { "default# ->x [g#a>=0:@space+100]", 1 },
		m { "->x", 2, k=50 }
	}

	given { ["g#a"] = {1, -1} }
	solution { x = {2} }

	given { ["g#a"] = {1, 1} }
	solution { x = {1} }
end)

test_solver_set_computed_constraint = _(function()
	graph {
		m { "default# ->x [g#a>=0:@space+100]", 1 },
		m { "->x", 2, k=50 },
		m { "g# g#a0->g#a", id },
	}

	given { ["g#a0"] = {1, -1} }
	solution { x = {2} }

	given { ["g#a0"] = {1, 1} }
	solution { x = {1} }
end)

test_solver_set_computed_param = _(function()
	graph {
		u { "first",
			ufunc(cf{0}, "k"),
			ufunc(function(inst) return inst == 0 and {0} or {} end, "i")
		},
		u { "second",
			ufunc(cf{1}, "k"),
			ufunc(function(inst) return inst == 1 and {0} or {} end, "i")
		},
		m { "default# ->g#a:first", 123 },
		m { "default# ->g#a:second", 456 },
		m { "default# g#a:second->x", id }
	}

	n.g = 2

	solution { x = {456} }
end)

test_solver_return_overlap = _(function()
	graph {
		m { "->x,y", {{1}, {1}}, k=1 },
		m { "->y,z", {{2}, {2}}, k=2 },
		m { "->x,z", {{3}, {3}}, k=3 }
	}

	solution { x = {1}, y = {1}, z = {2} }
end)

test_solver_no_chain_check = _(function()
	graph {
		m { "->x [a>=0+200]", 1, k=1 },
		m { "->x", 2, k=100},
		m { "->a [b>=0+inf]", 10 }
	}

	given { b = {-1} }
	solution { x = {2} }
end)

test_solver_lowbound_update = _(function()
	graph {
		m { "->z [a>=0+100]", 1},
		m { "z->y", 1 },
		m { "y->x", 1 },
		m { "->x", 2, k=50 }
	}

	-- solve x
	--     try y->x
	--         solve y
	--             try z->y
	--             fail, update z
	--         fail, update y
	--         (this asserts if y lowbound is too high)
	
	given { a={-1} }
	solution { x={2} }
end)

test_solver_check_donemask = _(function()
	-- this test depends on the order (x must be solved as root before y),
	-- so instead of doing it properly we just spray x's and hope that one of
	-- them is solved before y
	local solt = { y = {1} }

	local gs = {
		s { "y>=0", name="s" },
		m { "->y", 1 }
	}

	for i=1, 100 do
		table.insert(gs, m { string.format("->x%d [s+100]", i), i })
		solt[string.format("x%d", i)] = {i}
	end

	graph(gs)
	solution(solt)
end)

test_solver_stress_candidates = _(function()
	local ms = {}

	for i=1, 10 do
		table.insert(ms, m { string.format("->w%d", i), i, k=(i-1)/10 })
	end

	for i=1, 10 do
		-- min (i^2 - 10*i + 100 : i=1..10) = 75 (i = 5)
		table.insert(ms, m { string.format("->x%d", i), i, k=i^2, c=1 })
		table.insert(ms, m { string.format("->y%d", i), i, k=100-10*i, c=1 })

		for j=1, 10 do
			table.insert(ms, m {
				string.format("x%d,y%d,w%d->z", i, i, j),
				function(x, y, w) return {100*x[1] + 10*y[1] + w[1]} end
			})
		end
	end

	graph(ms)

	-- x5, y5, w1
	solution { z = { 551 } }
end)

test_solver_check_bitmap_over64 = _(function()
	local ws, xs = {}, {}

	for i=1, 100 do
		local v = i % 64
		ws[i] = v

		if v == 1 then                            xs[i] = 1
		elseif v == 2 or v == 3 or v == 4 then    xs[i] = 2
		elseif v == 15 or v == 16 or v == 17 then xs[i] = 3
		elseif v == 32 then                       xs[i] = 4
		elseif v == 63 then                       xs[i] = 5
		else                                      xs[i] = 0
		end
	end

	graph {
		v { "w", ctype="uint8_t" },
		m { "->x[w&1+inf]",        1 },
		m { "->x[w&2,3,4+inf]",    2 },
		m { "->x[w&15,16,17+inf]", 3 },
		m { "->x[w&32+inf]",       4 },
		m { "->x[w&63+inf]",       5 },
		m { "->x", k=100,          0 }
	}

	given { w = ws }
	solution { x = xs }
end)

test_solver_checkall_over64 = _(function()
	local ws = ffi.new("uint8_t[?]", 100)
	local xs = {}

	for i=0, 99 do
		ws[i] = i % 64
		xs[i+1] = (i % 64) == 63 and 1 or 0
	end

	graph {
		v { "w", ctype="uint8_t" },
		m { "->x", k=100,      0 },
		m { "->x[w&63+inf]",   1 }
	}

	given { w = { n=100, buf=ws } }
	solution { x = xs }
end)

test_solver_umap_association = _(function()
	local G = {}
	local data = {}
	local xs = {}

	local num = 20

	for i=1, num do
		table.insert(G, u {
			string.format("umap%d_g", i),
			ufunc(function() return {i-1} end, "i"),
			ufunc(function(inst) return inst == i-1 and {i-1} or {} end, "i")
		})

		table.insert(G, u {
			string.format("umap%d_default", i),
			ufunc(function() return {i-1} end, "i"),
			ufunc(function(inst) return inst == i-1 and {i-1} or {} end, "i")
		})

		table.insert(G, m {
			string.format("h# g%d#x%d:umap%d_g->default#x:umap%d_default", i, i, i, i),
			id
		})

		data[i] = i
		xs[string.format("g%d#x%d", i, i)] = data
	end

	n.h = num

	graph(G)
	given(xs)
	solution { x = data }
end)

test_edge_reordering = _(function()
	graph {
		m { "->x", 1 },
		m { "y,x->z", function(y,x) return {y[1]+x[1]} end }
	}

	given { y = {2} }
	solution { z = {3} }
end)

test_usermap_complex_retbuf = _(function()
	graph {
		u { "complex",
			ufunc(cf{0, 2}, "k"),
			ufunc(function(inst) return (inst == 0 or inst == 2) and {0} or {} end, "i")
		},
		m { "g# ->x:complex", cf{123,456} }
	}

	n.g = 1
	solution { x = {123, na, 456} }
end)

test_prune_omit_model = _(function()
	graph {
		m { "->x %1", k=1 },
		m { "->x %2", k=2 }
	}

	retain { "x" }
	selected {
		["->x %1"] = true,
		x = {1, }
	}
end)

test_prune_omit_given = _(function()
	graph {
		m { "x->y" },
		m { "y->z" }
	}

	given { "y" }
	retain { "z" }
	selected { "y", "z", "y->z" }
end)

test_prune_pick_bound = _(function()
	graph {
		s { "x>=0", name="s" },
		m { "x->y [s+100]" },
		m { "x->y", k=2 },
		m { "x->y [s+100] %k3", k=3 }
	}

	given { "x" }
	retain { "y" }
	selected { "x", "y", "x->y [s+100]", "x->y" }
end)

test_prune_omit_high_cycle = _(function()
	graph {
		m { "x->y", k=100},
		m { "y->x", k=1 },
		m { "x->z", k=1 },
		m { "y->z", k=1 },
		m { "->x",  k=100},
		m { "->y",  k=1 }
	}

	retain { "z" }
	selected { "y", "z", "y->z", "->y" }
end)

test_prune_retain_bounded_cycle = _(function()
	graph {
		m { "x->y" },
		m { "y->x" },
		m { "x->z" },
		m { "y->z" },
		m { "->x [w>=0+100]" },
		m { "->y [w<=0+100]" }
	}

	given { "w" }
	retain { "z" }
	selected {
		"x", "y", "z", "w",
		"x->y", "y->x", "x->z", "y->z", "->x [w>=0+100]", "->y [w<=0+100]"
	}
end)

test_prune_stress_heap = _(function()
	local ms = {}
	for i=1, 100 do
		table.insert(ms, m { string.format("->x%d", i), k=i, c=1 })
		table.insert(ms, m { string.format("x%d->x", i), k=200-2*i, c=1 })
	end

	-- min (i + 200-2*i : i=1..100) = 100  (i=100)

	graph(ms)
	retain { "x" }
	selected {
		"x", "x100", "->x100", "x100->x"
	}
end)
