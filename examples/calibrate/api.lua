define.enum.species {
	manty       = 1,
	kuusi       = 2,
	rauduskoivu = 3,
	hieskoivu   = 4,
	haapa       = 5,
	muu         = 6
}

define.vars {
	---------- puu ----------
	f       = "real",
	spe     = "species",
	dbh     = "real" * unit("cm"),
	ba      = "real" * unit("m^2"),
	ba_L    = "real" * unit("m^2"),
	ba_Lma  = "real" * unit("m^2"),
	ba_Lku  = "real" * unit("m^2"),
	ba_Lko  = "real" * unit("m^2"),
	--
	i_d     = "real" * unit("cm"),
	sur     = "real",

	---------- koeala ----------
	ts      = "real" * unit("degC"),
	G       = "real" * unit("m^2"),
	Gma     = "real" * unit("m^2"),
	mtyyppi = "bit64",
	atyyppi = "bit64",
	--
	fma     = "real",
	fku     = "real",
	fra     = "real",
	fhi     = "real",
	fle     = "real",

	---------- globaalit ----------
	step    = "real" * unit("yr")
}

define.type.tree {
	"f",
	"spe",
	"dbh",
	"ba",
	"ba_L",
	"ba_L",
	"ba_Lma",
	"ba_Lku",
	"ba_Lko"
}
