local pine_stratum_tpl = obj.stratum:template {
	species = enum.species.pine
}

local tree_tpl = obj.stratum:template {}

local stratums = world:create_objvec(obj.stratum)

local function plant_pines(N)
	local s = world:alloc_objvec(stratums, pine_stratum_tpl, 1)
	s[0][id.N] = N
	return s
end

local function generate_trees(s_ref)
	local trees = world:create_objvec(obj.tree)
	local t = world:alloc_objvec(trees, tree_tpl, 1)
	t[0][id.n] = s_ref[id.N]
	s_ref[id.trees] = trees
end

local s = plant_pines(10)
generate_trees(s[0])

----------------------------------------------------------

on("next_year", function()
	G.year = G.year + 1
	print("Nyt on vuosi:", G.year)
end)

local function maybe_plant(op)
	if op == "plant" then
		plant_pines(10)
	end
end

on("maybe_plant", function()
	branch(maybe_plant, {
		choice(0x1, "plant"),
		choice(0x2, "no plant")
	})
end)

----------------------------------------------------------

local instr = record()

for i=1, 2 do
	instr.next_year()
	instr.maybe_plant()
end

G.year = 0
simulate(instr)
