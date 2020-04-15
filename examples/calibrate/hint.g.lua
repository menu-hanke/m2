class.species {
	manty       = 1,
	kuusi       = 2,
	rauduskoivu = 3,
	hieskoivu   = 4,
	haapa       = 5,
	muu         = 6
}

hint {
	["tree#+dbh"] = "real",
	["tree#*f"]   = "real",
	["tree#spe"]  = "mask" * ofclass("species"),

	["+f/ma"]     = "real",
	["+f/ku"]     = "real",
	["+f/ra"]     = "real",
	["+f/hi"]     = "real",
	["+f/le"]     = "real"
}
