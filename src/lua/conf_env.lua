local typing = require "typing"
local env = setmetatable({ define={} }, {__index=_G})

-- This is global, use it to read config files
-- Note that this also works inside config files
function env.read(fname)
	if not fname then
		error("Missing file name to read()", 2)
	end

	local f, err = loadfile(fname, nil, env)

	if not f then
		error(string.format("Failed to read file: %s", err), 2)
	end

	f()
end

--------------------------------------------------------------------------------

local function namespace(index)
	return setmetatable({}, {
		__index=function(_, k)
			return function(...)
				index(k, ...)
			end
		end,
		__newindex=function(_, k, ...)
			index(k, ...)
		end
	})
end

local nodup_mt = {
	__index = function(self, k)
		return rawget(self._tab, k)
	end,
	__newindex = function(self, k, v)
		if self[k] then
			error(string.format(self._mes, k))
		end
		rawset(self._tab, k, v)
	end
}

local function nodup(tab, mes)
	return setmetatable({_tab=tab, _mes=mes}, nodup_mt)
end

local function totable(x)
	if type(x) ~= "table" then
		x = {x}
	end
	return x
end

--------------------------------------------------------------------------------
-- types
--------------------------------------------------------------------------------

local types = {}

local function gettype(name)
	if not types[name] then
		types[name] = { name=name, def={} }
	end
	return types[name]
end

local function setkind(type, name)
	if type.kind == name then
		return
	end

	if type.kind then
		error(string.format("Redefinition of type '%s' as kind '%s' (was previously '%s')",
			type.name, name, type.kind))
	end

	type.kind = name
end

local function setdef(type, k, v)
	if type.def[k] and type.def[k] ~= v then
		error(string.format("Redefinition of '%s' of type '%s' (%s -> %s)",
			k, type.name, type.def[k], v))
	end

	type.def[k] = v
end

env.define.enum = namespace(function(name, def)
	local e = gettype(name)
	setkind(e, "enum")

	for k,v in pairs(def) do
		setdef(e, k, tonumber(v))
	end
end)

env.define.type = namespace(function(name, def)
	local t = gettype(name)
	setkind(t, "struct")

	for k,v in pairs(def) do
		setdef(t, k, tostring(v))
	end
end)

env.C = typing.ctype

--------------------------------------------------------------------------------
-- fhk
--------------------------------------------------------------------------------

local models = {}
local vars = {}
local type_exports = {}

local _models = nodup(models, "Redefinition of model '%s'")
local _vars = nodup(vars, "Redefinition of var '%s'")

local function make_check(cst, cost_in, cost_out)
	cst.cost_in = cost_in or 0
	cst.cost_out = cost_out or math.huge

	-- the solver expects this
	-- see constraint_bounds() in fhk_solve.c
	if cst.cost_in > cst.cost_out then
		error(string.format("Expected cost_in<=cost_out but got %f>%f", cost_in, cost_out))
	end

	return cst
end

function env.set(...)
	return make_check({type="set", values={...}})
end

function env.ival(a, b)
	return make_check({type="ival", a=a, b=b})
end

local function parse_impl(impl)
	local lang, file, func = impl:match("([^:]+)::([^:]+)::(.+)$")
	if not lang then
		error(string.format("Invalid format: %s", impl))
	end
	return {lang=lang, file=file, func=func}
end

env.define.model = namespace(function(name, def)
	_models[name] = {
		name = name,
		params = totable(def.params or {}),
		returns = totable(def.returns or {}),
		checks = def.checks or {},
		impl = parse_impl(def.impl)
	}
end)

env.define.var = namespace(function(name, type)
	_vars[name] = type or "real"
end)

env.define.vars = function(defs)
	for name,t in pairs(defs) do
		if type(name) == "number" then
			_vars[t] = "real"
		else
			_vars[name] = t
		end
	end
end

env.fhk = {
	export = function(...)
		local ts = {...}
		for _,t in ipairs(ts) do
			type_exports[t] = true
		end
	end,

	read_coeff = function(fname)
		if not fname then
			error("Missing file name to read_calib()", 2)
		end

		local f = io.open(fname)
		if not f then
			error(string.format("Failed to read file '%s'", fname), 2)
		end

		local data = f:read("*a")
		local decode = require "json.decode"

		local coeffs = decode(data)

		for k,v in pairs(coeffs) do
			local m = models[k]

			if m then
				-- TODO: calibrated params also go here
				m.k = v.k
				m.c = v.c
			end

			-- TODO: this should probably cache the costs and then merge them to model
			-- when parsing conf because now this must be called after model definitions
			-- or it silently ignores costs
		end
	end
}

--------------------------------------------------------------------------------

return env, {
	types = types,
	models = models,
	vars = vars,
	type_exports = type_exports
}
