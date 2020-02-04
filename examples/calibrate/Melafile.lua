-- select R or Lua version of the models by commenting/uncommenting these
--local mdef = function(f, func) return model.R(string.format("%s.r::%s", f, func)) end
local mdef = function(f, func) return model.Lua(string.format("%s::%s", f:gsub("/", "."), func)) end

define.model.gro_manty {
	params  = { "step", "mtyyppi", "dbh", "G", "ba", "ba_L", "ts", "atyyppi" },
	checks  = { spe = "manty" },
	returns = { "i_d" },
	coeffs  = { "c_0", "c_sqrtd", "c_d", "c_logG", "c_baL", "c_logts", "c_omt", "c_vt", "c_ct", "c_suo"},
	impl    = mdef("models", "gro_manty")
}

define.model.gro_kuusi {
	params  = { "step", "mtyyppi", "dbh", "G", "ba", "ba_L", "ba_Lku", "ts" },
	checks  = { spe = "kuusi" },
	returns = { "i_d" },
	coeffs  = { "c_0", "c_sqrtd", "c_d", "c_logG", "c_baL", "c_baLku", "c_logts", "c_omt", "c_vt", "c_ct" },
	impl    = mdef("models", "gro_kuusi")
}

define.model.gro_lehti {
	params  = { "step", "mtyyppi", "dbh", "G", "ba", "ba_Lku", "ba_Lko", "ts", "spe" },
	checks  = { spe = any("rauduskoivu", "hieskoivu", "haapa", "muu") },
	returns = { "i_d" },
	coeffs  = { "c_0", "c_sqrtd", "c_d", "c_logG", "c_baL", "c_logts", "c_omt", "c_vt", "c_ct", "c_raha" },
	impl    = mdef("models", "gro_lehti")
}

define.model.sur_manty {
	params  = { "step", "dbh", "ba", "ba_L", "atyyppi" },
	checks  = { spe = "manty" },
	returns = { "sur" },
	coeffs  = { "c_0", "c_sqrtd", "c_d", "c_baL", "c_suo" },
	impl    = mdef("models", "sur_manty")
}

define.model.sur_kuusi {
	params  = { "step", "dbh", "ba", "ba_Lku", "atyyppi" },
	checks  = { spe = "kuusi" },
	returns = { "sur" },
	coeffs  = { "c_0", "c_sqrtd", "c_d", "c_baLku", "c_suo" },
	impl    = mdef("models", "sur_kuusi")
}

define.model.sur_lehti {
	params  = { "step", "dbh", "ba", "ba_Lma", "ba_Lku", "ba_Lko", "atyyppi", "spe" },
	checks  = { spe = any("rauduskoivu", "hieskoivu", "haapa", "muu") },
	returns = { "sur" },
	coeffs  = { "c_0", "c_sqrtd", "c_d", "c_baLma", "c_baLkuko", "c_suo", "c_koivu", "c_haapa" },
	impl    = mdef("models", "sur_lehti")
}

define.model.ingrowth_manty {
	params  = { "step", "ts", "G", "mtyyppi" },
	returns = { "fma" },
	coeffs  = { "c_0", "c_logts", "c_sqrtG", "c_omt", "c_vt" },
	impl    = mdef("models", "ingrowth_manty")
}

define.model.ingrowth_kuusi {
	params  = { "step", "ts", "G", "Gma", "mtyyppi" },
	returns = { "fku" },
	coeffs  = { "c_0", "c_logts", "c_sqrtG", "c_sqrtGma", "c_vtct" },
	impl    = mdef("models", "ingrowth_kuusi")
}

define.model.ingrowth_koivu {
	params  = { "step", "ts", "G", "Gma", "mtyyppi", "atyyppi" },
	returns = { "fra", "fhi"},
	coeffs  = { "c_0", "c_logts", "c_sqrtG", "c_sqrtGma", "c_vtct" },
	impl    = mdef("models", "ingrowth_koivu")
}

define.model.ingrowth_leppa {
	params  = { "step", "ts", "G", "mtyyppi" },
	returns = { "fle" },
	coeffs  = { "c_0", "c_logts", "c_sqrtG", "c_omt", "c_vtct" },
	impl    = mdef("models", "ingrowth_leppa")
}
