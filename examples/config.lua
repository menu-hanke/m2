define.enum.species {
	pine                 = 1,
	["Pinus sylvestris"] = 1,
	spruce               = 2,
	["Picea abies"]      = 2,
	silver_birch         = 3,
	["Betula pendula"]   = 3,
	white_birch          = 4,
	["Betula pubescens"] = 4,
	aspen                = 5,
	["Populus tremula"]  = 5,
	grey_alder           = 6,
	["Alnus incana"]     = 6,
	black_alder          = 7,
	["Alnus glutinosa"]  = 7,
	misc_coniferous      = 8,
	misc_decidious       = 9
}

define.type.biomass {
	BM_leaves = "real",
	BM_roots  = "real",
	BM_total  = "real"
}

define.type.tree {
	N       = "real",
	species = "species",
	age     = "real",
	d       = "real",
	h       = "real",
	biomass = "biomass"
}

fhk.export("tree")

--------------------------------------------------------------------------------

define.model.tree_d {
	params  = { "age", "species" },
	returns = { "d" },
	coeffs  = { "a", "b" },
	impl    = "R::examples/models2.r::tree_d"
}

define.model.tree_h {
	params  = { "age", "species" },
	returns = { "h" },
	impl    = "R::examples/models2.r::tree_h"
}

read.calib "examples/calib.json"
