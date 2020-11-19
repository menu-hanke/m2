-- select R or Lua version of the models by commenting/uncommenting these
--local mdef = function(f, func) return impl.R()string.format("R::%s.r::%s", f, func) end
local mdef = function(f, func) return impl.Lua(f:gsub("/", "."), func) end

derive ("plot#G" *as "double") {
	params "tree#ba" *set "all",
	mdef("vars", "G")
}

derive ("plot#G[manty]" *as "double") {
	params { "tree#ba", "tree#spe" } *set "all",
	mdef("vars", "Gmanty")
}

derive "plot#baL" {
	params "tree#ba" *set "all",
	returns "tree#baL" *set "all" *as "double",
	mdef("vars", "baL")
}

for _,spe in ipairs{"manty", "kuusi", "koivu"} do
	derive ("plot#baL[" .. spe .."]") {
		params { "tree#ba", "tree#spe" } *set "all",
		returns ("tree#baL[" .. spe .. "]") *set "all" *as "double",
		mdef("vars", "baL"..spe --[[ for example: , {call="p..kd:"..L(spe)} ]])
	}
end

-- TODO: the future of calibration is to do it like this:
-- * make a wrapper function that takes an impl and a list of coefficients
-- * allow reading the coeffs from an external file (specified in Melasim.lua?)
-- * autocalibration is the job of an external tool

model "tree#gro_manty" {
	params { "plot#step", "plot#mtyyppi", "tree#dbh", "plot#G", "tree#ba", "tree#baL", "plot#ts", "plot#atyyppi" },
	check "tree#spe" *is "manty",
	returns "tree#+dbh" *as "double",
	--coeffs { "c_0", "c_sqrtd", "c_d", "c_logG", "c_baL", "c_logts", "c_omt", "c_vt", "c_ct", "c_suo" },
	mdef("models", "gro_manty")
}

model "tree#gro_kuusi" {
	params { "plot#step", "plot#mtyyppi", "tree#dbh", "plot#G", "tree#ba", "tree#baL", "tree#baL[kuusi]", "plot#ts" },
	check "tree#spe" *is "kuusi",
	returns "tree#+dbh" *as "double",
	--coeffs { "c_0", "c_sqrtd", "c_d", "c_logG", "c_baL", "c_baLku", "c_logts", "c_omt", "c_vt", "c_ct" },
	mdef("models", "gro_kuusi")
}

model "tree#gro_lehti" {
	params { "plot#step", "plot#mtyyppi", "tree#dbh", "plot#G", "tree#ba", "tree#baL[kuusi]", "tree#baL[koivu]", "plot#ts", "tree#spe" },
	check "tree#spe" *is { "rauduskoivu", "hieskoivu", "haapa", "muu" },
	returns "tree#+dbh" *as "double",
	--coeffs { "c_0", "c_sqrtd", "c_d", "c_logG", "c_baL", "c_logts", "c_omt", "c_vt", "c_ct", "c_raha" },
	mdef("models", "gro_lehti")
}

model "tree#sur_manty" {
	params { "plot#step", "tree#dbh", "tree#ba", "tree#baL", "plot#atyyppi" },
	check "tree#spe" *is "manty",
	returns "tree#*f" *as "double",
	--coeffs { "c_0", "c_sqrtd", "c_d", "c_baL", "c_suo" },
	mdef("models", "sur_manty")
}

model "tree#sur_kuusi" {
	params { "plot#step", "tree#dbh", "tree#ba", "tree#baL[kuusi]", "plot#atyyppi" },
	check "tree#spe" *is "kuusi",
	returns "tree#*f" *as "double",
	--coeffs  { "c_0", "c_sqrtd", "c_d", "c_baLku", "c_suo" },
	mdef("models", "sur_kuusi")
}

model "tree#sur_lehti" {
	params { "plot#step", "tree#dbh", "tree#ba", "tree#baL[manty]", "tree#baL[kuusi]", "tree#baL[koivu]", "plot#atyyppi", "tree#spe" },
	check "tree#spe" *is { "rauduskoivu", "hieskoivu", "haapa", "muu" },
	returns "tree#*f" *as "double",
	--coeffs { "c_0", "c_sqrtd", "c_d", "c_baLma", "c_baLkuko", "c_suo", "c_koivu", "c_haapa" },
	mdef("models", "sur_lehti")
}

model "plot#ingrowth_manty" {
	params { "plot#step", "plot#ts", "plot#G", "plot#mtyyppi" },
	returns "plot#+f[manty]" *as "double",
	--coeffs { "c_0", "c_logts", "c_sqrtG", "c_omt", "c_vt" },
	mdef("models", "ingrowth_manty")
}

model "plot#ingrowth_kuusi" {
	params { "plot#step", "plot#ts", "plot#G", "plot#G[manty]", "plot#mtyyppi" },
	returns "plot#+f[kuusi]" *as "double",
	--coeffs { "c_0", "c_logts", "c_sqrtG", "c_sqrtGma", "c_vtct" },
	mdef("models", "ingrowth_kuusi")
}

model "plot#ingrowth_koivu" {
	params { "plot#step", "plot#ts", "plot#G", "plot#G[manty]", "plot#mtyyppi", "plot#atyyppi" },
	returns { "plot#+f[rauduskoivu]", "plot#+f[hieskoivu]"} *as "double",
	--coeffs { "c_0", "c_logts", "c_sqrtG", "c_sqrtGma", "c_vtct" },
	mdef("models", "ingrowth_koivu")
}

model "plot#ingrowth_leppa" {
	params { "plot#step", "plot#ts", "plot#G", "plot#mtyyppi" },
	returns "plot#+f[leppa]" *as "double",
	--coeffs { "c_0", "c_logts", "c_sqrtG", "c_omt", "c_vtct" },
	mdef("models", "ingrowth_leppa")
}
