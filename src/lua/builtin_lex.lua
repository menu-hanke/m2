-- some useful looking variables picked for testing from MELA manual
-- all resolutions are 0 for now since mela doesn't use spatial info
-- TODO: add (and actually implement) units
-- TODO: mela uses weird units, like cm for diameter but m for height,
--       maybe we should not use scaled units here (ie. m for every length, m^2 for area, etc.)

-- Note: you can have multiple names for a value
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

obj "tree"
	resolution(0)

	position "tree_z"

	var "N"
		-- I think we can have fractional trees?
		-- Note: the unit in mela is 1/ha but I think in a spatial simulator just a number
		-- is better?
		dtype "f64"
	
	var "species"
		dtype "species"
	
	var "d"
		-- diameter
		dtype "f64"
	
	var "ba"
		-- basal area
		dtype "f64"
	
	var "h"
		-- height
		dtype "f64"
	
	var "V"
		-- volume
		dtype "f64"
	
-- these are called both "management unit" variables and "sample plot" variables in mela??
-- in SIMO these are the top-level thing called management units I think?
-- Here we represent them as env variables

-- Note: year is represented as a 0-resolution env variable, maybe there's a nicer way to do this.
-- Note: this is relative to simulation start
env "year"
	resolution(0)
	dtype "f64"

-- Note: for the spatial version we don't actually need this, we can just count it from the grid
env "area"
	resolution(0)
	dtype "f64"

-- Note: all the categories below should be enums (TODO)

-- (11), land use category
env "landuse"
	resolution(0)
	dtype "b16"

-- (12), soil and peatland category
env "landtype"
	resolution(0)
	dtype "b16"

-- (13), site type category
env "sitetype"
	resolution(0)
	dtype "b16"

-- (16), drainage category
env "drainage"
	resolution(0)
	dtype "b16"
