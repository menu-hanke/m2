-- vim: ft=lua
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

---- sanity checks ----------------------------------------

test_san_single = _(function()
	graph {
		m { "a -> x", id }
	}

	given { a = {123} }
	solution { x = {123} }
end)

test_san_cost = _(function()
	graph {
		m { "-> x # M1", function() return {2} end, k=2},
		m { "-> x # M2", function() return {1} end, k=1}
	}

	solution { x = {1} }
end)

test_san_given_check = _(function()
	graph {
		m { "-> x # M1", function() return {1} end } :check "a>=0 +10",
		m { "-> x # M2", function() return {2} end } :check "a<=0 +10"
	}

	given { a = {1} }
	solution { x = {1} }

	given { a = {-1} }
	solution { x = {2} }
end)

test_san_computed_check = _(function()
	graph {
	 	m { "-> x", function() return {1} end },
		m { "-> y # M1", function() return {1} end, k=100, c=1},
		m { "-> y # M2", function() return {2} end, k=1, c=1} :check "x<=0 +1000"
	}

	solution { y = {1} }
end)

test_san_complex_parameter = _(function()
	graph {
		m { "a:even -> x", dot },
		p { "even",
			function() return set{0, 2} end,
			function(inst) return (inst%2==0) and set{0} or set() end
		},
		g { "a", size=4 }
	}

	given { a = {1, 2, 3, 4} }
	solution { x = {1+3} }
end)

test_san_chain = _(function()
	graph {
		m { "a -> x", id },
		m { "x -> y", id }
	}

	given { a = {123} }
	solution { x = {123} }
end)

test_san_set = _(function()
	graph {
		m { "a:@space -> x", dot },
		g { "a", size=3 }
	}

	given { a = {1, 2, 3} }
	solution { x = {1+2+3} }
end)

test_san_set_chain = _(function()
	graph {
		m { "a -> x # M", id },
		m { "x:@space -> y", dot },
		g { "a", "x", "M", size=3 }
	}

	given { a = {1, 2, 3} }
	solution { y = {1+2+3} }
end)

---- tech tests ----------------------------------------

test_tech_retbuf = _(function()
	graph {
		-- this model has complex returns so it doesn't set the FHK_MNORETBUF flag,
		-- ie it has to allocate the return buffers and then copy
		m { "-> x:@space", function() return {1, 2, 3} end },
		g { "x", size=3 }
	}

	solution { x = {1, 2, 3} }
end)

test_tech_instace_retbuf = _(function()
	graph {
		-- accessing the results here requires calculating the instance retbuf address
		m { "x,y -> z,w # M", id },
		g { "x", "y", "z", "w", "M", size=3 }
	}

	given { x = {1, 2, 3}, y = {4, 5, 6} }
	solution { z = {1, 2, 3}, w = {4, 5, 6} }
end)

test_tech_large_graph = _(function()
	local ms = {}
	for i=1, 255 do
		ms[i] = m { "x"..i..",y -> z"..i..",w # M"..i }
	end

	graph(ms)
end)

---- acyclic graphs ----------------------------------------

test_acy_bound_retry = _(function()
	graph {
		m { "x->a",  1, k=1, c=1},
		m { "y->a",  2, k=2, c=2},
		m { "xp->x", 3  } :check "xp>=0 +100" :check "xq>=0 +200",
		m { "yp->y", 4  } :check "yp>=0 +100" :check "yq>=0 +200",
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

test_acy_set_given_constraint = _(function()
	graph {
		m { "->x # M1", 1 } :check "a:@space>=0 +100",
		m { "->x # M2", 2, k=50 },
		g { "a", size=2 }
	}

	given { a = {1, -1} }
	solution { x = {2} }

	given { a = {1, 1} }
	solution { x = {1} }
end)

test_acy_set_computed_constraint = _(function()
	graph {
		m { "->x # M1", 1 } :check "a:@space>=0 +100",
		m { "->x # M2", 2, k=50 },
		m { "a0->a # M0", id },
		g { "a0", "a", "M0", size=2 }
	}

	given { a0 = {1, -1} }
	solution { x = {2} }

	given { a0 = {1, 1} }
	solution { x = {1} }
end)

test_acy_set_computed_param = _(function()
	graph {
		m { "a:second->x", id },
		m { "->a:first", 123 },
		m { "->a:second", 456 },
		p { "first",
			function() return set{0} end,
			function(inst) return inst == 0 and set{0} or set{} end
		},
		p { "second",
			function() return set{1} end,
			function(inst) return inst == 1 and set{0} or set{} end
		},
		g { "a", size=2 }
	}

	solution { x = {456} }
end)

test_acy_return_overlap = _(function()
	graph {
		m { "->x,y", {{1}, {1}}, k=1 },
		m { "->y,z", {{2}, {2}}, k=2 },
		m { "->x,z", {{3}, {3}}, k=3 }
	}

	solution { x = {1}, y = {1}, z = {2} }
end)

test_acy_no_chain_constraint = _(function()
	graph {
		m { "->x # M1", 1 } :check "a>=0 +100",
		m { "->x # M2", 2, k=200},
		m { "->a", 10 } :check "b>=0 +inf"
	}

	given { b = {-1} }
	solution { x = {2} }
end)

---- subgraph selection ----------------------------------------

test_sub_omit_model = _(function()
	graph {
		m { "->x # M1", k=1 },
		m { "->x # M2", k=2 }
	}

	root { "x" }
	subgraph { "x", "M1" }
end)

test_sub_omit_given = _(function()
	graph {
		m { "x->y" },
		m { "y->z" }
	}

	given { "y" }
	root { "z" }
	subgraph { "y", "z", "y->z" }
end)

test_sub_pick_bound = _(function()
	graph {
		m { "x->y # M1" } :check "x>=0 +100",
		m { "x->y # M2", k=2 },
		m { "x->y # M3", k=3 } :check "x>=0 +100"
	}

	given { "x" }
	root { "y" }
	subgraph { "x", "y", "M1", "M2" }
end)

test_sub_omit_high_cycle = _(function()
	graph {
		m { "x->y", k=100},
		m { "y->x" },
		m { "x->z" },
		m { "y->z" },
		m { "->x", k=100},
		m { "->y"  }
	}

	root { "z" }
	subgraph { "y", "z", "y->z", "->y" }
end)

test_sub_retain_bounded_cycle = _(function()
	graph {
		m { "x->y" },
		m { "y->x" },
		m { "x->z" },
		m { "y->z" },
		m { "->x"  } :check "w>=0 +100",
		m { "->y"  } :check "w<=0 +100"
	}

	given { "w" }
	root { "z" }
	subgraph {
		"x", "y", "z", "w",
		"x->y", "y->x", "x->z", "y->z", "->x", "->y"
	}
end)

-- TODO: reduce_fail tests
