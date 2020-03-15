-- vim: ft=lua
local ffi = require "ffi"
local bg = require "buildgraph"
local build, v, m = bg.build, bg.v, bg.m
local any, none, ival = bg.any, bg.none, bg.ival

local function valuetest(graph, answers)
	return function()
		local g, _, _, given = build(graph)
		local targets = {}
		for name,_ in pairs(answers) do table.insert(targets, name) end
		local solve = g:solve(targets)
		local r, res = solve(given)
		assert(r == true)
		for name,val in pairs(answers) do
			assert(res[name] == val)
		end
	end
end

local function failtest(graph, solve, status)
	return function()
		local g, _, _, given = build(graph)
		local r, err = g:solve(solve)(given)
		assert(r == false)
		assert(err.err == status)
	end
end

local function keyseq(tab, keys)
	local kl = {}

	-- keys <= tab
	for _,k in ipairs(keys) do
		assert(tab[k] ~= nil)
		kl[k] = true
	end

	-- tab <= keys
	for k,_ in pairs(tab) do
		assert(kl[k])
	end
end

local function reducetest(graph1, opt)
	return function()
		local g, _, _, given = build(graph1)
		g:given_values(given)
		local r, h = g:reduce(opt.ys)
		if opt.fails then
			assert(r == false)
			assert(h.err == opt.fails)
		else
			assert(r == true)
			if opt.vars then keyseq(h.vars, opt.vars) end
			if opt.models then keyseq(h.models, opt.models) end
		end
	end
end

--------------------------------------------------------------------------------

test_1model = valuetest(
{
	m("malli", 0) + "x" - "a",
	v("x", 0)
},
{
	a = 0
})

test_selection = valuetest(
{
	m("halpa",  1) * {k=1, c=1} + "x" - "a",
	m("kallis", 2) * {k=2, c=1} + "x" - "a",
	v("x", 0)
},
{
	a = 1
})

test_chain_selection = valuetest(
{
	m("halpa_pitka_ketju", 1)  * {k=1, c=1}   + {"x", "y"} - "a",
	m("malli_x", 2)            * {k=100, c=1}              - "x",
	m("malli_y", 3)            * {k=10, c=1}               - "y",
	m("kallis_lyhyt_ketju", 4) * {k=5, c=1}                - "a"
},
{
	a = 4
})

test_multi_return = valuetest(
{
	m("malli_xy", {1, 2})      * {k=100, c=1} - {"x", "y"},
	m("malli_yz", {10, 20})    * {k=10, c=1}  - {"y", "z"},
	m("malli_xz", {100, 200})  * {k=1, c=1}   - {"x", "z"}
},
{
	x = 100,
	y = 10,
	z = 200
})

test_cycle = valuetest(
{
	m("cy_a0", 1)   * {k=15, c=1} + "a0" - "a",
	m("cy_b0", 2)   * {k=5, c=1}  + "b0" - "b",
	m("cy_b2a", 10)               + "b"  - "a",
	m("cy_a2b", 20)               + "a"  - "b",
	v("a0", 0),
	v("b0", 0)
},
{
	a = 10,
	b = 2
})

test_reject_constraint = valuetest(
{
	m("halpa", 1)  % "x"^ival{-1, 1} * {k=1, c=1}   + "x" - "a",
	m("kallis", 2)                   * {k=100, c=1} + "x" - "a",
	v("x", 2)
},
{
	a = 2
})

test_accept_constraint = valuetest(
{
	m("halpa", 1)  % "x"^any{1,2,3} * {k=1, c=1}   + "x" - "a",
	m("kallis", 2)                  * {k=100, c=1} + "x" - "a",
	v("x", 2)^"mask"
},
{
	a = 1
})

test_computed_check = valuetest(
{
	m("halpa", 1)    % "x"^ival{-1, 1} * {k=1, c=1}   + "x" - "a",
	m("kallis", 2)                     * {k=100, c=1} + "x" - "a",
	m("malli_yx", 0)                                  + "y" - "x",
	v("y", 0)
},
{
	a = 1
})

test_recursive_model_bound = valuetest(
{
	m("x,y->a,b", {1, 2})                  + {"x", "y"} - {"a", "b"},
	m("b->y", 3)                           + "b"        - "y",
	m("y0", 4)            * {k=100, c=100}              - "y",
	v("x", 0),
},
{
	a = 1
})

test_partial_beta_bound = valuetest(
{
	m("x->a", 1)  * {k=1, c=1} + "x" - "a",
	m("y->a", 2)  * {k=2, c=2} + "y" - "a",
	m("xp,xq->x", 3) % "xp"^ival{0, 1, m=0, M=100} % "xq"^ival{0, 1, m=0, M=200}
	                           + "xp" - "x",
	m("yp,yq->y", 4) % "yp"^ival{0, 1, m=0, M=100} % "yq"^ival{0, 1, m=0, M=200}
	                           + "yp" - "y",
	m("xp0", -1)               - "xp",
	m("xq0", 0.5)              - "xq",
	m("yp0", 0.5)              - "yp",
	m("yq0", -1)               - "yq"
},
{
	a = 1
})

test_fail_no_chain = failtest(
{
	m("malli") + "x" - "a"
},
{ "a" }, ffi.C.FHK_SOLVER_FAILED)

test_fail_constraint = failtest(
{
	m("malli_1") % "x"^ival{-math.huge, -1} + "x" - "a",
	m("malli_2") % "x"^ival{1, math.huge}   + "x" - "a",
	v("x", 0)
},
{ "a" }, ffi.C.FHK_SOLVER_FAILED)

test_reduce1 = reducetest(
{
	m("malli") + "x" - "a",
	v("x", 0)
},
{
	ys     = {"a"},
	vars   = {"x", "a"},
	models = {"malli"}
})

test_reduce_omit_model = reducetest(
{
	m("halpa")  * {k=1,   c=1  } + "x" - "a",
	m("kallis") * {k=100, c=100} + "x" - "a",
	v("x", 0)
},
{
	ys     = {"a"},
	vars   = {"x", "a"},
	models = {"halpa"}
})

test_reduce_omit_var = reducetest(
{
	m("halpa")  * {k=1,   c=1  } + "x" - "a",
	m("kallis") * {k=100, c=100} + "y" - "a",
	v("x", 0),
	v("y", 0)
},
{
	ys     = {"a"},
	vars   = {"x", "a"},
	models = {"halpa"}
})

test_reduce_keep_strict_beta = reducetest(
{
	m("mcst")   % "x"^ival{100, 200} * {k=1,   c=1}   + "x" - "a",
	m("mnocst")                      * {k=100, c=100} + "x" - "a",
	v("x", 0)
},
{
	ys     = {"a"},
	vars   = {"x", "a"},
	models = {"mcst", "mnocst"}
})

test_reduce_skip_high_beta = reducetest(
{
	m("m1")   % "x"^ival{100, 200}           + "x" - "a",
	m("m2")   % "x"^ival{0, 1, m=50, M=100}  + "x" - "a",
	m("m3")   % "x"^ival{1, 2, m=100, M=100} + "x" - "a",
	v("x", 0)
},
{
	ys     = {"a"},
	vars   = {"x", "a"},
	models = {"m1", "m2"}
})

test_reduce_omit_high_cycle = reducetest(
{
	m("x->y") * {k=100, c=100} + "x" - "y",
	m("y->x")                  + "y" - "x",
	m("x->z")                  + "x" - "z",
	m("y->z")                  + "y" - "z",
	m("x_0")  * {k=100, c=100} - "x",
	m("y_0")                   - "y"
},
{
	ys     = {"z"},
	vars   = {"y", "z"},
	models = {"y->z", "y_0"}
})

test_reduce_retain_bounded_cycle = reducetest(
{
	m("x->y")                  + "x" - "y",
	m("y->x")                  + "y" - "x",
	m("x->z")                  + "x" - "z",
	m("y->z")                  + "y" - "z",
	m("x_0")  % "w"^ival{0, 1} - "x",
	m("y_0")  % "w"^ival{1, 2} - "y",
	v("w", 0)
},
{
	ys     = {"z"},
	vars   = {"x", "y", "z", "w"},
	models = {"x->y", "y->x", "x->z", "y->z", "x_0", "y_0"}
})

test_reduce_fail_no_solution = reducetest(
{
	m("x->y") + "x" - "y"
},
{
	ys    = {"y"},
	fails = ffi.C.FHK_SOLVER_FAILED
})
