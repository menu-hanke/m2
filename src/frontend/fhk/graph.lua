local function nodeset()
	return {
		models  = {},
		vars    = {},
		shadows = {}
	}
end

local function model(name, init)
	init = init or {}
	init.name = name
	init.params = init.params or {}
	init.returns = init.returns or {}
	init.shadows = init.shadows or {}
	return init
end

local function var(name, init)
	init = init or {}
	init.name = name
	return init
end

local function shadow(name, var, guard, arg)
	return {
		name  = name,
		var   = var,
		guard = guard,
		arg   = arg
	}
end

local function edge(target, map, init)
	init = init or {}
	init.target = target
	init.map = map
	return init
end

local function shedge(target, map, penalty)
	return {
		target  = target,
		map     = map,
		penalty = penalty
	}
end

local function umap(map, inverse, flags)
	return {
		map     = map,
		inverse = inverse,
		flags   = flags
	}
end

local function ufunc(create, flags, name)
	return {
		create = create,
		flags  = flags,
		name   = name
	}
end

local function isconst(flags)
	return flags:match("k")
end

local function groupof(name)
	return name:match("^(.-)#.*$")
end

return {
	nodeset  = nodeset,
	model    = model,
	var      = var,
	shadow   = shadow,
	edge     = edge,
	shedge   = shedge,
	umap     = umap,
	ufunc    = ufunc,
	isconst  = isconst,
	groupof  = groupof
}
