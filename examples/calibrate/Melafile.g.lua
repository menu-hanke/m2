-- select R or Lua version of the models by commenting/uncommenting these
--local mdef = function(f, func) return string.format("R::%s.r::%s", f, func) end
local mdef = function(f, func) return string.format("Lua::%s::%s", f:gsub("/", "."), func) end

model.gro_manty {
	params  = { "plot#step", "plot#mtyyppi", "tree#dbh", "plot#G", "tree#ba", "tree#baL", "plot#ts", "plot#atyyppi" },
	checks  = { ["tree#spe"] = "manty" },
	returns = { "tree#+dbh" },
	coeffs  = { "c_0", "c_sqrtd", "c_d", "c_logG", "c_baL", "c_logts", "c_omt", "c_vt", "c_ct", "c_suo"},
	impl    = mdef("models", "gro_manty")
}

model.gro_kuusi {
	params  = { "plot#step", "plot#mtyyppi", "tree#dbh", "plot#G", "tree#ba", "tree#baL", "tree#baL/ku", "plot#ts" },
	checks  = { ["tree#spe"] = "kuusi" },
	returns = { "tree#+dbh" },
	coeffs  = { "c_0", "c_sqrtd", "c_d", "c_logG", "c_baL", "c_baLku", "c_logts", "c_omt", "c_vt", "c_ct" },
	impl    = mdef("models", "gro_kuusi")
}

model.gro_lehti {
	params  = { "plot#step", "plot#mtyyppi", "tree#dbh", "plot#G", "tree#ba", "tree#baL/ku", "tree#baL/ko", "plot#ts", "tree#spe" },
	checks  = { ["tree#spe"] = any("rauduskoivu", "hieskoivu", "haapa", "muu") },
	returns = { "tree#+dbh" },
	coeffs  = { "c_0", "c_sqrtd", "c_d", "c_logG", "c_baL", "c_logts", "c_omt", "c_vt", "c_ct", "c_raha" },
	impl    = mdef("models", "gro_lehti")
}

model.sur_manty {
	params  = { "plot#step", "tree#dbh", "tree#ba", "tree#baL", "plot#atyyppi" },
	checks  = { ["tree#spe"] = "manty" },
	returns = { "tree#*f" },
	coeffs  = { "c_0", "c_sqrtd", "c_d", "c_baL", "c_suo" },
	impl    = mdef("models", "sur_manty")
}

model.sur_kuusi {
	params  = { "plot#step", "tree#dbh", "tree#ba", "tree#baL/ku", "plot#atyyppi" },
	checks  = { ["tree#spe"] = "kuusi" },
	returns = { "tree#*f" },
	coeffs  = { "c_0", "c_sqrtd", "c_d", "c_baLku", "c_suo" },
	impl    = mdef("models", "sur_kuusi")
}

model.sur_lehti {
	params  = { "plot#step", "tree#dbh", "tree#ba", "tree#baL/ma", "tree#baL/ku", "tree#baL/ko", "plot#atyyppi", "tree#spe" },
	checks  = { ["tree#spe"] = any("rauduskoivu", "hieskoivu", "haapa", "muu") },
	returns = { "tree#*f" },
	coeffs  = { "c_0", "c_sqrtd", "c_d", "c_baLma", "c_baLkuko", "c_suo", "c_koivu", "c_haapa" },
	impl    = mdef("models", "sur_lehti")
}

model.ingrowth_manty {
	params  = { "plot#step", "plot#ts", "plot#G", "plot#mtyyppi" },
	returns = { "+f/ma" },
	coeffs  = { "c_0", "c_logts", "c_sqrtG", "c_omt", "c_vt" },
	impl    = mdef("models", "ingrowth_manty")
}

model.ingrowth_kuusi {
	params  = { "plot#step", "plot#ts", "plot#G", "plot#G/ma", "plot#mtyyppi" },
	returns = { "+f/ku" },
	coeffs  = { "c_0", "c_logts", "c_sqrtG", "c_sqrtGma", "c_vtct" },
	impl    = mdef("models", "ingrowth_kuusi")
}

model.ingrowth_koivu {
	params  = { "plot#step", "plot#ts", "plot#G", "plot#G/ma", "plot#mtyyppi", "plot#atyyppi" },
	returns = { "+f/ra", "+f/hi"},
	coeffs  = { "c_0", "c_logts", "c_sqrtG", "c_sqrtGma", "c_vtct" },
	impl    = mdef("models", "ingrowth_koivu")
}

model.ingrowth_leppa {
	params  = { "plot#step", "plot#ts", "plot#G", "plot#mtyyppi" },
	returns = { "+f/le" },
	coeffs  = { "c_0", "c_logts", "c_sqrtG", "c_omt", "c_vtct" },
	impl    = mdef("models", "ingrowth_leppa")
}
