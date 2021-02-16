local cli = require "cli"

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
	return self
end

function code_mt.__index:emitf(fmt, ...)
	self:emit(string.format(fmt, ...))
	return self
end

local function try_format(x)
	local formatter = os.getenv("M2_CODE_FORMATTER")

	if formatter then
		try_format = function(src)
			local proc = io.popen(string.format([[
				%s <<EOF
				%s]].."\nEOF", formatter, src))
			src = proc:read("*a")
			proc:close()
			return src
		end
	else
		try_format = function(src)
			return src
		end
	end

	return try_format(x)
end

function code_mt.__index:compile(env, name)
	name = name or "=(code)"
	local src = tostring(self)

	if cli.verbosity <= -2 then
		cli.debug("%s %s\n%s", cli.magenta "emit", cli.bold(name),
			cli.magenta "> " .. try_format(src):gsub("\n", cli.magenta "\n> "))
	end

	local f, err = load(src, name, t, env)
	if not f then
		error(string.format("Compile failed: %s", err))
	end
	return f
end

local function getupvalueiv(f, name)
	local i = 1
	while true do
		local n, v = debug.getupvalue(f, i)

		if not n then
			error(string.format("function %s has no upvalue '%s'", f, name))
		end

		if n == name then
			return i, v
		end

		i = i+1
	end
end

local function getupvalue(f, name)
	local _, v = getupvalueiv(f, name)
	return v
end

local function setupvalue(f, name, v)
	debug.setupvalue(f, getupvalueiv(f, name), v)
end

return {
	new        = new,
	getupvalue = getupvalue,
	setupvalue = setupvalue
}
