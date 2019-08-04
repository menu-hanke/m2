-- some useful looking variables picked for testing from MELA manual
-- all resolutions are 0 for now since mela doesn't use spatial info
-- TODO: add (and actually implement) units
-- TODO: mela uses weird units, like cm for diameter but m for height,
--       maybe we should not use scaled units here (ie. m for every length, m^2 for area, etc.)

obj "tree"
	resolution(0)

	var "N"
		-- I think we can have fractional trees?
		-- Note: the unit in mela is 1/ha but I think in a spatial simulator just a number
		-- is better?
		dtype "f64"
	
	var "species"
		-- TODO: this will be an actual enum but enums are not implemented yet
		dtype "b16"
	
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
