local log = require("log").logger

local code_mt = { __index={} }

local function new()
	return setmetatable({}, code_mt)
end

function code_mt:__tostring()
	return table.concat(self, "\n")
end

function code_mt:__add(other)
	return setmetatable({tostring(self), tostring(other)}, code_mt)
end

function code_mt.__index:emit(s)
	table.insert(self, s)
end

function code_mt.__index:emitf(fmt, ...)
	self:emit(string.format(fmt, ...))
end

function code_mt.__index:compile(env, name)
	name = name or "=(code)"
	local src = tostring(self)
	log:debug("[code] %s\n%s", name, src)
	return load(src, name, t, env)
end

return {
	new = new
}
