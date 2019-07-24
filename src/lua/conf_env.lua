local env = setmetatable({}, {__index={}})

env.inf = math.huge

-- These affect the simulation core:
-- types are used to create vars and vars are used to compose objects
local types = {}
local vars = {}
local objs = {}

-- These only affect the fhk graph:
-- virtual variables are usually aggregates etc. expensive to compute values that
-- may or may not be needed, models are used to compute values
local fhk_models = {}
local fhk_virtuals = {}

-- config file state
local active_stack = {}

local function verify_stack(stack, elvl)
	elvl = elvl and (elvl+1) or 1

	for i,v in ipairs(stack) do
		if not active_stack[i] then
			error(string.format("Expected inside '%s'", v), elvl)
		end
		if active_stack[i].kind ~= v then
			error(string.format("Expected inside '%s' but found '%s'", v, active_stack[i].kind),
				elvl)
		end
	end
end

local function setactive(def, elvl, ...)
	local stack = {...}
	local idx = #stack
	local kind = stack[idx]
	stack[idx] = nil

	verify_stack(stack, elvl+1)

	active_stack[idx] = { def=def, kind=kind }
	for i=idx+1, #active_stack do
		active_stack[i] = nil
	end

	return def
end

local function getactive(elvl, ...)
	local stack = {...}
	verify_stack(stack, elvl+1)
	return active_stack[#stack].def
end

local function ac(...)
	return getactive(2, ...)
end

local function new(tab, name, obj, tabname, elvl)
	elvl = elvl or 3

	if tab[name] then
		error(string.format("Duplicate definition of %s '%s'", tabname or "", name), elvl)
	end

	local ret = obj or {}
	tab[name] = ret
	return ret
end

local function newactive(tab, name, obj, ...)
	local kind = select(-1, ...)
	local ret = new(tab, name, obj, kind, 4)
	return setactive(ret, 2, ...)
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
	new(types, name, {
		type = "enum",
		name = name,
		def = def
	}, "type")
end

-------------------
-- vars
-------------------

function env.var(name)
	newactive(vars, name, {
		name = name
	}, "var")
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
-- objects
-----------------------

function env.obj(name)
	newactive(objs, name, {
		name = name
	}, "obj")
end

function env.fields(...)
	ac("obj").fields = {...}
end

function env.uprefs(...)
	ac("obj").uprefs = {...}
end

-----------------------
-- models
-----------------------

function env.model(name)
	newactive(fhk_models, name, {
		name = name,
		checks = {},
		params = {}
	}, "model")
end

function env.param(name)
	local model = ac("model")
	newactive(model.params, name, name, "model", "parameter")
	-- Note: parameter order matters, use the integer indices
	table.insert(model.params, name)
end

function env.check(cst, cost_in, cost_out, var)
	var = var or ac("model", "parameter")

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

---------------------

return env, {
	types=types,
	vars=vars,
	objs=objs,
	fhk_models=fhk_models,
	fhk_virtuals=fhk_virtuals
}
