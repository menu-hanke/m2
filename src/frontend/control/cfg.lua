-- note: cfg as in "control flow graph", not configuration.

local function tagof(node)
	return type(node) == "table" and node.tag or nil
end

local function isprimitive(node)
	return tagof(node) == "primitive"
end

local function isnothing(node)
	return tagof(node) == "nothing"
end

local nothing = {
	tag  = "nothing",
	emit = function(...) return require("control.emit").nothing(...) end
}

local exit = {
	tag  = "exit",
	emit = function(...) return require("control.emit").exit(...) end
}

local function primitive(f, narg, args)
	return {
		tag   = "primitive",
		emit  = require("control.emit").primitive,
		f     = f,
		narg  = narg or 0,
		args  = args or {}
	}
end

local function export(f, narg, args)
	return {
		tag   = "export",
		f     = f,
		narg  = narg or 0,
		args  = args or {}
	}
end

local function all(edges)
	return {
		tag   = "all",
		emit  = require("control.emit").all,
		edges = edges
	}
end

local function any(edges)
	return {
		tag   = "any",
		emit  = require("control.emit").any,
		edges = edges
	}
end

local function optional(node)
	return any { node, nothing }
end

local function _walk(node, f, seen)
	if seen[node] then
		return
	end

	seen[node] = true

	f(node)

	if node.edges then
		for _,e in ipairs(node.edges) do
			_walk(e, f, seen)
		end
	end
end

local function walk(cfg, f)
	_walk(cfg, f, {})
end

return {
	tagof          = tagof,
	isprimitive    = isprimitive,
	isnothing      = isnothing,

	nothing        = nothing,
	exit           = exit,
	primitive      = primitive,
	export         = export,
	all            = all,
	any            = any,
	optional       = optional,

	walk           = walk
}
