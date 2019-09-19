define.enum.species {
	manty       = 1,
	kuusi       = 2,
	rauduskoivu = 3,
	hieskoivu   = 4,
	haapa       = 5,
	muu         = 6
}

define.type.tree {
	f      = "real",
	spe    = "species",
	dbh    = "real",
	ba     = "real",
	ba_L   = "real",
	ba_Lma = "real",
	ba_Lku = "real",
	ba_Lko = "real"
}

define.type.plot {
	trees   = "udata", -- vec("tree")
	time    = "real",
	step    = "real",
	ts      = "real",
	G       = "real",
	Gma     = "real",
	mtyyppi = "bit64",
	atyyppi = "bit64"
}

fhk.export "tree"
fhk.export "plot"

--------------------------------------------------------------------------------

define.vars {
	"i_d",  -- d increment
	"sur",  -- survival probability
	"fma", "fku", "fra", "fhi", "fle", -- ingrowth per species
}

define.model.gro_manty {
	params  = { "step", "mtyyppi", "dbh", "G", "ba", "ba_L", "ts", "atyyppi" },
	checks  = { spe = "manty" },
	returns = { "i_d" },
	coeffs  = { "c_0", "c_sqrtd", "c_d", "c_logG", "c_baL", "c_logts", "c_omt", "c_vt", "c_ct", "c_suo"},
	impl    = "R::examples/models_cal.r::gro_manty"
}

define.model.gro_kuusi {
	params  = { "step", "mtyyppi", "dbh", "G", "ba", "ba_L", "ba_Lku", "ts" },
	checks  = { spe = "kuusi" },
	returns = { "i_d" },
	coeffs  = { "c_0", "c_sqrtd", "c_d", "c_logG", "c_baL", "c_baLku", "c_logts", "c_omt", "c_vt", "c_ct" },
	impl    = "R::examples/models_cal.r::gro_kuusi"
}

define.model.gro_lehti {
	params  = { "step", "mtyyppi", "dbh", "G", "ba", "ba_Lku", "ba_Lko", "ts", "spe" },
	checks  = { spe = any("rauduskoivu", "hieskoivu", "haapa", "muu") },
	returns = { "i_d" },
	coeffs  = { "c_0", "c_sqrtd", "c_d", "c_logG", "c_baL", "c_logts", "c_omt", "c_vt", "c_ct", "c_raha" },
	impl    = "R::examples/models_cal.r::gro_lehti"
}

define.model.sur_manty {
	params  = { "step", "dbh", "ba", "ba_L", "atyyppi" },
	checks  = { spe = "manty" },
	returns = { "sur" },
	coeffs  = { "c_0", "c_sqrtd", "c_d", "c_baL", "c_suo" },
	impl    = "R::examples/models_cal.r::sur_manty"
}

define.model.sur_kuusi {
	params  = { "step", "dbh", "ba", "ba_Lku", "atyyppi" },
	checks  = { spe = "kuusi" },
	returns = { "sur" },
	coeffs  = { "c_0", "c_sqrtd", "c_d", "c_baLku", "c_suo" },
	impl    = "R::examples/models_cal.r::sur_kuusi"
}

define.model.sur_lehti {
	params  = { "step", "dbh", "ba", "ba_Lma", "ba_Lku", "ba_Lko", "atyyppi", "spe" },
	checks  = { spe = any("rauduskoivu", "hieskoivu", "haapa", "muu") },
	returns = { "sur" },
	coeffs  = { "c_0", "c_sqrtd", "c_d", "c_baLma", "c_baLkuko", "c_suo", "c_koivu", "c_haapa" },
	impl    = "R::examples/models_cal.r::sur_lehti"
}

define.model.ingrowth_manty {
	params  = { "step", "ts", "G", "mtyyppi" },
	returns = { "fma" },
	coeffs  = { "c_0", "c_logts", "c_sqrtG", "c_omt", "c_vt" },
	impl    = "R::examples/models_cal.r::ingrowth_manty"
}

define.model.ingrowth_kuusi {
	params  = { "step", "ts", "G", "Gma", "mtyyppi" },
	returns = { "fku" },
	coeffs  = { "c_0", "c_logts", "c_sqrtG", "c_sqrtGma", "c_vtct" },
	impl    = "R::examples/models_cal.r::ingrowth_kuusi"
}

define.model.ingrowth_koivu {
	params  = { "step", "ts", "G", "Gma", "mtyyppi", "atyyppi" },
	returns = { "fra", "fhi"},
	coeffs  = { "c_0", "c_logts", "c_sqrtG", "c_sqrtGma", "c_vtct" },
	impl    = "R::examples/models_cal.r::ingrowth_koivu"
}

define.model.ingrowth_leppa {
	params  = { "step", "ts", "G", "mtyyppi" },
	returns = { "fle" },
	coeffs  = { "c_0", "c_logts", "c_sqrtG", "c_omt", "c_vtct" },
	impl    = "R::examples/models_cal.r::ingrowth_leppa"
}
