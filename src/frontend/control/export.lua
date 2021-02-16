local cfg = require "control.cfg"
local emit = require "control.emit"

local export_mt = {
	__index = function(self, name)
		self[name] = function(...)
			return cfg.export(name, select("#", ...), {...})
		end
		return self[name]
	end
}

local function exports()
	return setmetatable({}, export_mt)
end

local function packprimitive(f, ...)
	return f, select("#", ...), {...}
end

local function toprimitive(f, narg, args)
	if type(f) == "function" then
		return f, narg, args
	end

	return packprimitive(f.toprimitive(unpack(args, 1, narg)))
end

local function patch_exports(G, export)
	cfg.walk(G, function(node)
		if node.tag == "export" then
			local f = export[node.f] or error(string.format("name not exported: '%s'", node.f))
			local g, narg, args = toprimitive(f, node.narg, node.args)

			node.tag = "primitive"
			node.emit = emit.primitive
			node.f = g or error(string.format("export didn't return a function: '%s'", node.f))
			node.narg = narg
			node.args = args
		end
	end)
end

local function make_primitive(f)
	return { toprimitive=f }
end

return {
	exports        = exports,
	patch_exports  = patch_exports,
	make_primitive = make_primitive
}
