-- vim: ft=lua
local ffi = require "ffi"
local T = require "testgraph"
local testenv = T.injector(T.inject_test)

local function g(f)
	return setfenv(f, testenv())
end

test_1model = g(function()
	graph {
		m("x->a", 0)
	}

	given { x = 0 }
	solution { a = 0 }
end)

test_selection = g(function()
	graph {
		m("halpa:x->a", 1)  :cost{k=1, c=1},
		m("kallis:x->a", 2) :cost{k=2, c=1}
	}

	given { x = 0 }
	solution { a = 1 }
end)

test_chain_selection = g(function()
	graph {
		m("x,y->a", 1) :cost{k=1, c=1},
		m("->x", 2)    :cost{k=100, c=1},
		m("->y", 3)    :cost{k=10, c=1},
		m("->a", 4)    :cost{k=5, c=1}
	}

	solution { a = 4 }
end)

test_multi_return = g(function()
	graph {
		m("->x,y", {1,2})      :cost{k=100, c=1},
		m("->y,z", {10,20})    :cost{k=10, c=1},
		m("->x,z", {100, 200}) :cost{k=1, c=1}
	}

	solution { x=100, y=10, z=200 }
end)

test_cycle = g(function()
	graph {
		m("a0->a", 1) :cost{k=15, c=1},
		m("b0->b", 2) :cost{k=5, c=1},
		m("b->a", 10),
		m("a->b", 20)
	}

	given { a0=0, b0=0 }
	solution { a=10, b=2 }
end)

test_interval_constraint = g(function()
	graph {
		m("halpa:x->a", 1)  :check{x=between(-1, 1)} :cost{k=1, c=1},
		m("kallis:x->a", 2)                          :cost{k=100, c=1}
	}

	given { x = 2 }
	solution { a = 2 }

	given { x = 0 }
	solution { a = 1 }
end)

test_mask_constraint = g(function()
	graph {
		m("halpa:x->a", 1)  :check{x=any(1,2,3)} :cost{k=1, c=1},
		m("kallis:x->a", 2)                      :cost{k=100, c=1}
	}

	given { x = ffi.new("pvalue", {u64=2^2}) }
	solution { a = 1 }

	given { x = ffi.new("pvalue", {u64=2^4}) }
	solution { a = 2 }
end)

test_computed_check = g(function()
	graph {
		m("halpa:x->a", 1)  :check{x=between(-1, 1)} :cost{k=1, c=1},
		m("kallis:x->a", 2)                          :cost{k=100, c=1},
		m("y->x", 0)
	}

	given { y = 0 }
	solution { a = 1 }
end)

test_recursive_model_bound = g(function()
	graph {
		m("x,y->a,b", {1, 2}),
		m("b->y", 3),
		m("->y", 4) :cost{k=100, c=100}
	}

	given { x = 0 }
	solution { a = 1 }
end)

test_partial_beta_bound = g(function()
	graph {
		m("x->a", 1) :cost{k=1, c=1},
		m("y->a", 2) :cost{k=2, c=2},
		m("xp->x", 3):check{xp=between(0, 1), xq=between(0, 1)}:xcost{xp={0, 100}, xq={0, 200}},
		m("yp->y", 4):check{yp=between(0, 1), yq=between(0, 1)}:xcost{yp={0, 100}, yq={0, 200}},
		m("->xp", -1),
		m("->xq", 0.5),
		m("->yp", 0.5),
		m("->yq", -1)
	}

	solution { a = 1 }
end)

test_fail_no_chain = g(function()
	graph {
		m("x->a")
	}

	want { "a" }
	solution( failure { err = ffi.C.FHK_SOLVER_FAILED } )
end)

test_fail_constraint = g(function()
	graph {
		m("1:x->a"):check{x=between(-math.huge, -1)},
		m("2:x->a"):check{x=between(1, math.huge)}
	}

	given { x = 0 }
	want { "a" }
	solution( failure { err = ffi.C.FHK_SOLVER_FAILED } )
end)

test_reduce1 = g(function()
	graph {
		m("x->a")
	}

	given { "x" }
	want { "a" }
	reduces { "x", "a", "x->a"}
end)

test_reduce_omit_model = g(function()
	graph {
		m("halpa:x->a")  :cost{k=1, c=1},
		m("kallis:x->a") :cost{k=100, c=100}
	}

	given { "x" }
	want { "a" }
	reduces { "x", "a", "halpa" }
end)

test_reduce_omit_var = g(function()
	graph {
		m("x->a") :cost{k=1, c=1},
		m("y->a") :cost{k=100, c=100}
	}

	given { "x", "y" }
	want { "a" }
	reduces { "x", "a", "x->a" }
end)

test_reduce_keep_strict_beta = g(function()
	graph {
		m("cst:x->a")   :check{x=between(100, 200)} :cost{k=1, c=1},
		m("nocst:x->a")                             :cost{k=100, c=100}
	}

	given { "x" }
	want { "a" }
	reduces { "x", "a", "cst", "nocst" }
end)

test_reduce_skip_high_beta = g(function()
	graph {
		m("1:x->a"):check{x=between(100, 200)},
		m("2:x->a"):check{x=between(0, 1)}:xcost{x={50, 100}},
		m("3:x->a"):check{x=between(1, 2)}:xcost{x={100, 100}}
	}

	given { "x" }
	want { "a" }
	reduces { "x", "a", "1", "2" }
end)

test_reduce_omit_high_cycle = g(function()
	graph {
		m("x->y"):cost{k=100, c=100},
		m("y->x"),
		m("x->z"),
		m("y->z"),
		m("->x"):cost{k=100, c=100},
		m("->y")
	}

	want { "z" }
	reduces { "y", "z", "y->z", "->y" }
end)

test_reduce_retain_bounded_cycle = g(function()
	graph {
		m("x->y"),
		m("y->x"),
		m("x->z"),
		m("y->z"),
		m("->x"):check{w=between(0, 1)},
		m("->y"):check{w=between(1, 2)}
	}

	given { "w" }
	want { "z" }
	reduces {
		"x", "y", "z", "w",
		"x->y", "y->x", "x->z", "y->z", "->x", "->y"
	}
end)

test_reduce_fail_no_solution = g(function()
	graph {
		m("x->y")
	}

	want { "y" }
	reduces( failure { err = ffi.C.FHK_SOLVER_FAILED } )
end)
