local env = setmetatable({}, {__index={}})

env.inf = math.huge

-- These affect the simulation core:
-- types are used to create vars and vars are used to compose objects
local types = {}
local vars = {}

-- These only affect the fhk graph:
-- virtual variables are usually aggregates etc. expensive to compute values that
-- may or may not be needed, models are used to compute values
local fhk_models = {}
local fhk_virtuals = {}

-- config file state
local active, active_kind
local active_param

local function ac(t)
	if not active then
		error("Invalid position for direvtive", 3)
	end

	if t and active_kind ~= t then
		error(string.format("This directive is valid inside '%s', not '%s'",
			t, active_kind), 3)
	end

	return active
end

local function newtype(name, def)
	if types[name] then
		error(string.format("Duplicate definition of type '%s'", name), 2)
	end

	types[name] = def
end

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

-- Use this to read json parameter files from config
function env.read_coeff(fname)
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
		local m = fhk_models[k]

		if m then
			-- TODO: calibrated params also go here
			m.k = v.k
			m.c = v.c
		end

		-- silently ignore uknown models.
		-- could also print a warning here?
	end
end

-------------------
-- types
-------------------

function env.enum(name, def)
	newtype(name, {type="enum", name=name, def=def})
end

-------------------
-- vars
-------------------

function env.var(name)
	if vars[name] then
		error(string.format("Duplicate var '%s'", name), 2)
	end

	active = { name=name }
	active_kind = "var"
	vars[name] = active
end

function env.dtype(type)
	ac("var").type = type
end

function env.unit(name)
	ac("var").unit = name
end

function env.desc(name)
	ac("var").desc = name
end

-----------------------
-- models
-----------------------

function env.model(name)
	if fhk_models[name] then
		error(string.format("Duplicate model '%s'", name), 2)
	end

	active = { name=name, checks={}, params={} }
	active_kind = "model"
	active_param = nil
	fhk_models[name] = active
end

function env.param(name)
	if ac("model").params[name] then
		error(string.format("Duplicate parameter '%s' in model '%s'",
			name, active.name), 2)
	end

	active.params[name] = true
	-- Note: parameter order matters, use the integer indices
	table.insert(active.params, name)
	active_param = name
end

function env.check(cst, cost_in, cost_out, var)
	var = var or active_param

	if not var then
		error("No parameter specified for check", 2)
	end

	cost_in = cost_in or 0
	cost_out = cost_out or math.huge

	-- the solver expects this
	-- see constraint_bounds() in fhk_solve.c
	if cost_in > cost_out then
		error(string.format("Expected cost_in<=cost_out but got %f>%f", cost_in, cost_out))
	end

	table.insert(ac("model").checks, {
		var=var,
		cst=cst,
		cost_in=cost_in,
		cost_out=cost_out
	})
end

function env.returns(var)
	ac("model").returns = var
end

function env.impl(impl)
	local lang, file, func = impl:match("([^:]+)::([^:]+)::(.+)$")
	if not lang then
		error("Invalid format")
	end

	ac("model").impl = { lang=lang, file=file, func=func }
end

--------------------
-- virtuals
--------------------

function env.virtual(name)
end

--------------------
-- constraints
--------------------

function env.set(...)
	return {type="set", values={...}}
end

function env.ival(a, b)
	return {type="ival", a=a, b=b}
end

return env, {
	types=types,
	vars=vars,
	fhk_models=fhk_models,
	fhk_virtuals=fhk_virtuals
}
