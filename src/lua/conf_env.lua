local env_mt = {}
local env = setmetatable({}, env_mt)
local root = {}

-- config file state
local stack = {}
local topidx = 0

function env_mt:__index(f)
	for i=#stack, 1, -1 do
		local s = stack[i]
		local fd = s.def[f]
		if fd then
			return function(...)
				topidx = i
				local res, err = pcall(fd, ...)
				if not res then
					-- re-raise it here so traceback shows the correct line in config file
					error(err, 2)
				end
			end
		end
	end

	error(string.format("Directive '%s' is not valid here", f), 2)
end

local function push(def, e)
	for i=topidx+1, #stack do
		stack[i] = nil
	end

	stack[topidx+1] = {e=e, def=def}
	return e
end

local function top(offset)
	offset = offset or 0
	return stack[topidx - offset].e
end

local function idx(offset)
	return stack[offset].e
end

-- Expose some generic stuff
env.inf = math.huge

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
	local fhk_models = idx(1).fhk_models

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
-- util
-------------------

local function setter(name)
	return function(x)
		top()[name] = x
	end
end

local function numeric_setter(name)
	return function(x)
		top()[name] = tonumber(x)
	end
end

local function set_resolution(res)
	top().z_order = 2*tonumber(res)
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

-------------------
-- types
-------------------

local type_ = {

}

function root.enum(name, def)
	top()._types[name] = push(type_, {
		name = name,
		def  = def,
		kind = "enum"
	})
end

-----------------------
-- objects
-----------------------

local obj_var = {
	dtype = setter("type"),
	unit = setter("unit")
}

local obj = {
	resolution = set_resolution,
	var = function(name)
		top()._vars[name] = push(obj_var, {
			name = name,
			type = "f64",
			obj = top()
		})
	end,
	position = function(name)
		local obj = top()
		if obj.position_var then
			error(string.format("Position variable already defined as '%s'", obj.position_var.name))
		end

		obj.position_var = {
			name = name,
			type = "z",
			obj = obj
		}
		
		obj._vars[name] = obj.position_var
	end
}

function root.obj(name)
	-- allow re-pushing defined obj to add more details e.g. from multiple config files
	local o = top().objs[name]
	if not o then
		local vars = {}
		o = {
			name = name,
			vars = vars,
			_vars = nodup(vars, "Duplicate variable '%s'")
		}
		top().objs[name] = o
	end

	push(obj, o)
end

-----------------------
-- envs
-----------------------

local env_ = {
	dtype = setter("type"),
	unit = setter("unit"),
	resolution = set_resolution,
}

function root.env(name)
	top()._envs[name] = push(env_, {
		name = name,
		resolution = 0,
		dtype = "f64"
	})
end

-----------------------
-- models
-----------------------

local function make_check(cst, cost_in, cost_out, var)
	cost_in = cost_in or 0
	cost_out = cost_out or math.huge

	-- the solver expects this
	-- see constraint_bounds() in fhk_solve.c
	if cost_in > cost_out then
		error(string.format("Expected cost_in<=cost_out but got %f>%f", cost_in, cost_out))
	end

	return {
		var=var,
		cst=cst,
		cost_in=cost_in,
		cost_out=cost_out
	}
end

local param = {
	check = function(cst, cost_in, cost_out)
		table.insert(top(1).checks, make_check(cst, cost_in, cost_out, top()))
	end
}

local model = {
	param = function(name)
		push(param, name)
		top()._params[name] = true
		table.insert(top().params, name)
	end,
	returns = function(name)
		top()._returns[name] = true
		table.insert(top().returns, name)
	end,
	check = function(cst, cost_in, cost_out, var)
		table.insert(top().checks, make_check(cst, cost_in, cost_out, var))
	end,
	impl = function(impl)
		local lang, file, func = impl:match("([^:]+)::([^:]+)::(.+)$")
		if not lang then
			error(string.format("Invalid format: %s", impl))
		end
		top().impl = { lang=lang, file=file, func=func }
	end
}

function root.model(name)
	local params = {}
	local returns = {}
	top()._fhk_models[name] = push(model, {
		name = name,
		checks = {},
		params = params,
		returns = returns,
		_params = nodup(params, "Parameter '%s' specified twice"),
		_returns = nodup(returns, "Return value '%s' specified twice")
	})
end

--------------------
-- virtuals
--------------------

function root.virtual(name)
end

--------------------
-- vars
--------------------

local var = {
	dtype = setter("type"),
	unit = setter("unit")
}

function root.var(name)
	top()._vars[name] = push(var, {
		name = name,
		dtype = "f64"
	})
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

function env.objvec(obj)
	return {type="objvec", obj=obj}
end

--------------------

local types = {}
local objs = {}
local envs = {}
local fhk_models = {}
local fhk_virtuals = {}
local vars = {}

return env, push(root, {
	types = types,
	objs = objs,
	envs = envs,
	fhk_models = fhk_models,
	fhk_virtuals = fhk_virtuals,
	vars = vars,
	_types = nodup(types, "Redefinition of type '%s'"),
	_objs = nodup(objs, "Redefinition of object '%s'"),
	_envs = nodup(envs, "Redefinition of env '%s'"),
	_fhk_models = nodup(fhk_models, "Redefinition of model '%s'"),
	_fhk_virtuals = nodup(fhk_virtuals, "Redefinition of virtual '%s'"),
	_vars = nodup(vars, "Redefinition of variable '%s'")
})
