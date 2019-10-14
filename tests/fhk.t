-- vim: ft=lua
local ffi = require "ffi"
local bg = require "buildgraph"
local build, v, m = bg.build, bg.v, bg.m
local any, none, ival = bg.any, bg.none, bg.ival

local function valuetest(graph, values)
	return function()
		local g = build(graph)
		local solve = {}
		for name,_ in pairs(values) do table.insert(solve, name) end
		local r = g:solve(g:vpointers(solve))
		assert(r == ffi.C.FHK_OK)
		for name,val in pairs(values) do
			assert(g:value(name) == val)
		end
	end
end

local function failtest(graph, solve, status)
	return function()
		local g = build(graph)
		local r = g:solve(g:vpointers(solve))
		assert(r == status)
	end
end

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
	v("x", 2)^"bit64"
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
