-- basic models - compute y from either directly from real x and category c
-- or indirectly with intermediate var z

model "Mb_1"
	param "x"
	param "c" check(set(1, 2, 3))

	returns "y"
	impl "R::examples/models1.r::Mb_1"
	returns "y2"
	impl "R::examples/models1.r::Mb_1"

model "Mb_2"
	param "c"

	returns "z"
	impl "R::examples/models1.r::Mb_2"

-- "better" but more specific model for case c=4
model "Mb_2v2"
	-- check c=4 but don't take it as a parameter
	-- the syntax is a bit awkward?
	check(set(4), 0, inf, "c")

	returns "z"
	impl "R::examples/models1.r::Mb_2v2"

model "Mb_3"
	param "z" check(ival(0, inf))

	returns "y"
	impl "R::examples/models1.r::Mb_3"
	returns "y2"
	impl "R::examples/models1.r::Mb_3"

model "Mb_4"
	param "z" check(ival(-inf, 0))

	returns "w"
	impl "R::examples/models1.r::Mb_4"

-- cyclic models - x and x' are "equivalent" in the sense that they can be estimated
-- from each other but one MUST be given

-- TODO (check models1.r): conversion syntax?
-- eg. model M returns exp(x) but model M' takes x as parameter

model "Mc_1"
	param "x"
	returns "x'"

	impl "R::examples/models1.r::Mc_1"

model "Mc_2"
	param "x'"

	returns "x"
	impl "R::examples/models1.r::Mc_2"

-- cyclic models for dijkstra

model "cy_a2b"
	param "a" -- check(ival(-inf, 0))
	returns "b"
	impl "R::examples/models1.r::cy_a2b"

model "cy_b2a"
	param "b"
	returns "a"
	impl "R::examples/models1.r::cy_b2a"

model "cy_a0"
	param "a0"
	returns "a"
	impl "R::examples/models1.r::cy_a0"

model "cy_b0"
	param "b0"
	returns "b"
	impl "R::examples/models1.r::cy_b0"

model "cy_d"
	param "a"
	param "b"
	returns "d"
	impl "R::examples/models1.r::cy_d"
