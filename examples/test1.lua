local Tree = obj("Tree", types.tree)

-- global tree vector
local trees = Tree:vec()

local function plant_trees(n, spec)
	local pos = trees:alloc(n)

	local age = trees:band("age")
	local spe = trees:band("species")
	local d = trees:band("d")

	for i=pos, pos+n-1 do
		age[i] = 0
		spe[i] = spec
		d[i] = 0
	end
end

local function do_operation(op)
	print("tehdään operaatio: ", op)

	if op == "istutus" then
		print("istutetaan kuusi")
		plant_trees(1, enum.species.spruce)
	end
end

--------------------------------------------------------------------------------

on("grow", function()
	print("10 mäntyä syntyy")
	plant_trees(10, enum.species.pine)
end)

on("grow#1", function()
	print("puut kasvavat")
	local d = trees:band("d")
	local newd = trees:newband("d")
	for i=0, trees:len()-1 do
		newd[i] = d[i] + 10
	end
	trees:swap("d", newd)
	print(string.format("puun[0] d: %f -> %f", d[0], newd[0]))
end)

on("operation", function()
	print("haaraudutaan")

	branch(do_operation, {
		choice(0x1, "istutus"),
		choice(0x2, "ei mitään")
	})

	print("haarautuminen loppui")
end)

on("report", function(i)
	local dsum = 0
	local d = trees:band("d")
	for i=0, trees:len()-1 do
		dsum = dsum + d[i]
	end

	print("raportti[", i, "] h summa: ", dsum)
end)

--------------------------------------------------------------------------------

local instr = record()

for i=1, 2 do
	instr.grow()
	instr.operation()
	instr.grow()
	instr.report(i)
end

print("simulointi alkaa tästä.")
simulate(instr)
