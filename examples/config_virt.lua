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
	spe    = "species"
}

--------------------------------------------------------------------------------

define.vars {
	"x",
	"is_koivu"
}

define.model.koivumalli {
	params  = { "is_koivu" },
	returns = "x",
	impl    = "Lua::examples.models_virt::koivumalli"
}
