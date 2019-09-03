define.vars {
	"x",
	"x'",
	"w",
	"a0",
	"a",
	"b0",
	"b",
	"d",
	"z",
	"y",
	"y2",
	c = "bit64"
}

define.model.Mb_1 {
	params  = {"x", "c"},
	checks  = { c = set(1, 2, 3) },
	returns = {"y", "y2"},
	impl    = "R::examples/models1.r::Mb_1"
}

define.model.Mb_2 {
	params  = "c",
	returns = "z",
	impl    = "R::examples/models1.r::Mb_2"
}

-- "better" but more specific model for case c=4
define.model.Mb_2v2 {
	checks  = { c = set(4) },
	returns = "z",
	impl    = "R::examples/models1.r::Mb_2v2"
}

define.model.Mb_3 {
	params  = "z",
	checks  = { z = ival(0, math.huge) },
	returns = {"y", "y2"},
	impl    = "R::examples/models1.r::Mb_3"
}

define.model.Mb_4 {
	params  = "z",
	checks  = { z = ival(-math.huge, 0) },
	returns = "w",
	impl    = "R::examples/models1.r::Mb_4"
}

-- cyclic models - x and x' are "equivalent" in the sense that they can be estimated
-- from each other but one MUST be given

define.model.Mc_1 {
	params  = "x",
	returns = "x'",
	impl    = "R::examples/models1.r::Mc_1"
}

define.model.Mc_2 {
	params  = "x'",
	returns = "x",
	impl    = "R::examples/models1.r::Mc_2"
}

-- cyclic models for dijkstra

define.model.cy_a2b {
	params  = "a",
	returns = "b",
	impl    = "R::examples/models1.r::cy_a2b"
}

define.model.cy_b2a {
	params  = "b",
	returns = "a",
	impl    = "R::examples/models1.r::cy_b2a"
}

define.model.cy_a0 {
	params  = "a0",
	returns = "a",
	impl    = "R::examples/models1.r::cy_a0"
}

define.model.cy_b0 {
	params  = "b0",
	returns = "b",
	impl    = "R::examples/models1.r::cy_b0"
}

define.model.cy_d {
	params  = {"a", "b"},
	returns = "d",
	impl    = "R::examples/models1.r::cy_d"
}

fhk.read_coeff "examples/coeff.json"
