local misc = require "misc"

local edef_mt = { __index={} }
local ev_mt = { __index={ block_time = 0.000001, kind = "optional" } }

local function edef()
	return setmetatable({
		events = {},
		rules  = {},
		_n     = 0
	}, edef_mt)
end

function edef_mt.__index:event(name, attrs)
	if self.events[name] then
		error(string.format("Redefinition of event '%s'", name))
	end

	local ev = setmetatable({
		name = name,
		check = {},
		order = self._n
	}, ev_mt)

	self._n = self._n + 1

	for _,a in ipairs(attrs) do
		a(ev)
	end

	self.events[name] = ev
	return ev
end

function edef_mt.__index:rule(rule)
	table.insert(self.rules, rule)
end

function edef_mt.__index:finalize()
	for _,r in ipairs(self.rules) do
		for _,e in pairs(self.events) do
			r(e)
		end
	end
end

local function tomatch(x)
	if type(x) == "table" then
		local fs = {}
		for i,f in ipairs(x) do
			fs[i] = tomatch(f)
		end

		return function(s)
			for _,f in ipairs(fs) do
				if f(s) then
					return true
				end
			end

			return false
		end
	end

	if type(x) == "function" then
		return x
	end

	if type(x) == "string" then
		x = "^" .. x .. "$"
		return function(e)
			return e.name:match(x)
		end
	end

	if type(x) == "boolean" then
		return function()
			return x
		end
	end

	error(string.format("Invalid matcher: '%s'", x))
end

local function lazy_op(name, ...)
	local op = {f=name, x={...}}
	return function(e)
		e.op = op
	end
end

local function matcher_attr(name)
	return function(x)
		return function(e)
			if e[name] then
				x = {e[name], x}
			end
			e[name] = tomatch(x)
		end
	end
end

local edef_func = setmetatable({
	check = function(f)
		return function(e)
			table.insert(e.check, f)
		end
	end,

	blocked_time = function(t)
		return function(e)
			e.block_time = t
		end
	end,

	operation = setmetatable({}, {
		__index = function(self, name)
			return function(...) return lazy_op(name, ...) end
		end
	}),

	forced = function(e)
		e.kind = "forced"
	end,

	blocked_by = matcher_attr("blocked_by"),
	blocks = matcher_attr("blocks"),
	before = matcher_attr("before"),
	after = matcher_attr("after"),
	requires = matcher_attr("requires")
}, {__index=_G})

local function edef_env(def, ops)
	local env = setmetatable({
		rule = function(match)
			match = tomatch(match)
			return function(attrs)
				return def:rule(function(e)
					if match(e) then
						for _,a in ipairs(attrs) do
							a(e)
						end
					end
				end)
			end
		end,

		event = function(name)
			return function(attrs)
				return def:event(name, attrs)
			end
		end,

		operation = ops
	}, {__index=edef_func})

	env.read = function(fname) return misc.dofile_env(env, fname) end
	return env
end

local function read(...)
	local def = edef()
	local env = edef_env(def)

	for _,f in ipairs({...}) do
		env.read(f)
	end

	return def
end

return {
	create = edef,
	env    = edef_env,
	read   = read
}
