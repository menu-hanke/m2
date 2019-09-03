local Tree = obj("Tree", types.tree)
fhk.expose(Tree)

local trees = Tree:vec()
trees:alloc(10)

local ages = trees:band("age")
local species = trees:band("species")
for i=0, 9 do
	ages[i] = i
	species[i] = enum.species.spruce
end

local d_solver = fhk.solve("d"):from(Tree)
d_solver(trees)

local res = d_solver:res("d")
for i=0, 9 do
	print(i, res[i])
end
