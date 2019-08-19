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
