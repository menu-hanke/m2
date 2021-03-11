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

local function shallowmerge(dest, src)
	for k,v in pairs(src) do
		if dest[k] then
			error(string.format("duplicate node: '%s'", k))
		end
		dest[k] = v
	end
end

local function merge(...)
	local ret = nodeset()
	
	for _,ns in ipairs({...}) do
		shallowmerge(ret.models, ns.models)
		shallowmerge(ret.vars, ns.vars)
		shallowmerge(ret.shadows, ns.shadows)
	end

	return ret
end

local function groupof(name)
	return name:match("^(.-)#.*$")
end

return {
	nodeset = nodeset,
	model   = model,
	var     = var,
	shadow  = shadow,
	edge    = edge,
	shedge  = shedge,
	merge   = merge,
	groupof = groupof
}
