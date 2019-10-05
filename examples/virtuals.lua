Tree = obj("Tree", types.tree)
fhk.expose(Tree)

trees = Tree:vec()

local vc = 0
fhk.virtual("is_koivu", Tree, function(idx)
	local spe = trees:band("spe")[idx]
	vc = vc+1
	return bit.band(spe, enum.species.rauduskoivu + enum.species.hieskoivu)
end)

local solve_koivu = fhk.solve("x"):from(Tree)

on("init", function()
	local pos = trees:alloc(5)
	local spe = trees:band("spe")

	spe[pos] = enum.species.manty
	spe[pos+1] = enum.species.kuusi
	spe[pos+2] = enum.species.rauduskoivu
	spe[pos+3] = enum.species.hieskoivu
	spe[pos+4] = enum.species.haapa
end)

on("test", function()
	solve_koivu(trees)
	local spe = trees:band("spe")
	local x = solve_koivu:res("x")

	for i=0, trees:len()-1 do
		print(string.format("i: %d spe: %d x: %f", i, spe[i], x[i]))
	end
end)

on("done", function()
	print("done", trees:len())
	print("virt calls", vc)
end)
