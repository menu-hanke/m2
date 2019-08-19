enum("species", {
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
})

-- ks. simo
enum("soilclass", {
	very_rich = 1,
	rich      = 2,
	damp      = 3,
	dryish    = 4,
	dry       = 5,
	barren    = 6,
	rocky     = 7,
	hilltop   = 8
})

obj "stratum"
	var "trees"   dtype(objvec("tree"))
	var "species" dtype "species"
	var "N"       dtype "f64"
	var "D_gM"    dtype "f64"
	var "D_hM"    dtype "f64"
	var "SI_50"   dtype "f64"
	-- TODO: jne.

obj "tree"
	var "n"     dtype "f64"
	var "age"   dtype "f64"
	var "a"     dtype "f64"
	var "d"     dtype "f64"
	var "d_s"   dtype "f64"
	var "ba"    dtype "f64"
	var "ba_L"  dtype "f64"
	var "rdf_L" dtype "f64"
	var "cr"    dtype "f64"
	var "ga"    dtype "f64"
	var "h"     dtype "f64"
	var "v"     dtype "f64"
	-- TODO: biomass

-- TODO: many of these don't change so they can be made readonly
-- (and save 16 bytes of vstack space per global!)
global "year" dtype "f64"
global "sc"   dtype "soilclass"
global "ts"   dtype "f64"
