hint {
	a = "real",
	b = "real",
	c = "mask" * ofclass("puulaji"),
	x = "real"
}

class.puulaji {
	manty = 1,
	kuusi = 2,
	koivu = 3
}

model.ab2x {
	params  = {"a", "b"},
	returns = "x",
	impl    = "R::models.r::ab2x"
}

model.ac2x {
	params  = {"a", "c"},
	returns = "x",
	impl    = "R::models.r::ac2x"
}
