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
	pstep   = "real",
	ts      = "real",
	G       = "real",
	mtyyppi = "bit64",
	atyyppi = "bit64"
}

fhk.export "tree"
fhk.export "plot"

--------------------------------------------------------------------------------

define.vars {
	"step", -- time step
	"i_d",  -- d increment
}

define.model.gro_manty {
	params  = { "step", "mtyyppi", "dbh", "G", "ba_L", "ts", "atyyppi" },
	checks  = { spe = "manty" },
	returns = { "i_d" },
	coeffs  = { "c_0", "c_sqrtd", "c_d", "c_logG", "c_baL", "c_logts", "c_omt", "c_vt", "c_ct", "c_suo"},
	impl    = "R::examples/models_cal.r::gro_manty"
}

define.model.gro_kuusi {
	params  = { "step", "mtyyppi", "dbh", "G", "ba_L", "ba_Lku", "ts" },
	checks  = { spe = "kuusi" },
	returns = { "i_d" },
	coeffs  = { "c_0", "c_sqrtd", "c_d", "c_logG", "c_baL", "ca_baLku", "c_logts", "c_omt", "c_vt", "c_ct" },
	impl    = "R::examples/models_cal.r::gro_kuusi"
}

define.model.gro_lehti {
	params  = { "step", "mtyyppi", "dbh", "G", "ba_Lku", "ba_Lko", "ts", "spe" },
	checks  = { spe = any("rauduskoivu", "hieskoivu", "haapa", "muu") },
	returns = { "i_d" },
	coeffs  = { "c_0", "c_sqrtd", "c_d", "c_logG", "c_baL", "c_logts", "c_omt", "c_vt", "c_ct", "c_raha" },
	impl    = "R::examples/models_cal.r::gro_lehti"
}
