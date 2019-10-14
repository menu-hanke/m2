local typing = require "typing"
local env = setmetatable({ define={} }, {__index=_G})

local function read_json(fname)
	if not fname then
		error("Missing file name")
	end

	local f = io.open(fname)
	if not f then
		error(string.format("Failed to read file '%s'", fname))
	end

	local data = f:read("*a")
	local decode = require "json.decode"
	return decode(data)
end

-- This is global, use it to read config files
-- Note that this also works inside config files
env.read = setmetatable({}, {__call = function(_, fname)
	if not fname then
		error("Missing file name to read()", 2)
	end

	local f, err = loadfile(fname, nil, env)

	if not f then
		error(string.format("Failed to read file: %s", err), 2)
	end

	f()
end})

--------------------------------------------------------------------------------

local calib = {}

env.read.calib = function(fname)
	local cals = read_json(fname)
	for k,v in pairs(cals) do
		calib[k] = v
	end
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

local function gettype(name, kind, create)
	if types[name] then
		if types[name].kind == kind then
			return types[name]
		end

		error(string.format("Redefinition of type '%s' of different kind (%s -> %s)",
			name, types[name].kind, kind))
	end

	types[name] = create(name, kind)
	return types[name]
end

local function newenum(name) return {name=name, kind="enum", def={}} end
local function newstruct(name) return {name=name, kind="struct", def={}, lazy={}} end
local function getenum(name) return gettype(name, "enum", newenum) end
local function getstruct(name) return gettype(name, "struct", newstruct) end

env.define.enum = namespace(function(name, def)
	local e = getenum(name)

	for k,v in pairs(def) do
		v = tonumber(v)

		if e.def[k] and e.def[k] ~= v then
			error(string.format("Redefinition of enum '%s' value '%s' (%d -> %d)",
				name, k, e.def[k], v))
		end

		e.def[k] = v
	end
end)

env.define.type = namespace(function(name, def)
	local t = getstruct(name)

	for k,v in pairs(def) do
		if type(k) == "number" then
			t.lazy[v] = true
		else
			if t.def[k] and t.def[k] ~= v then
				error(string.format(
					"Redefinition of struct '%s' member '%s' with conflicting type (%s -> %s)",
					name, k, t.def[k], v
				))
			end

			t.def[k] = v
		end
	end
end)

env.C = typing.ctype

--------------------------------------------------------------------------------
-- fhk
--------------------------------------------------------------------------------

local models = {}
local vars = {}

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

function env.any(...)
	return make_check({type="any", values={...}})
end

function env.none(...)
	return make_check({type="none", values={...}})
end

function env.between(a, b)
	return make_check({type="interval", a = a or -math.huge, b = b or math.huge})
end

env.model = setmetatable({}, {
	__index = function(self, k)
		self[k] = function(opt)
			return {lang=k, opt=opt}
		end
		return self[k]
	end
})

env.model.Const = function(...)
	return {lang="Const", opt={...}}
end

local function parse_impl(impl)
	local lang, opt = impl:match("^([^:]+)::(.+)$")
	if not lang then
		error(string.format("Invalid format: %s", impl))
	end
	return {lang=lang, opt=opt}
end

env.define.model = namespace(function(name, def)
	local checks = def.checks or {}
	for var,cst in pairs(checks) do
		if type(cst) == "string" then
			checks[var] = env.any(cst)
		end
	end

	_models[name] = {
		name = name,
		params = totable(def.params or {}),
		returns = totable(def.returns or {}),
		coeffs = totable(def.coeffs or {}),
		checks = checks,
		impl = type(def.impl) == "string" and parse_impl(def.impl) or def.impl
	}
end)

---------- vars ----------

local vdef_mt = {}

local function vdef(d)
	return setmetatable(d, vdef_mt)
end

env.unit = function(unit) return vdef({unit=unit}) end
env.doc  = function(doc)  return vdef({doc=doc}) end

local function paste(dest, tab)
	for k,v in pairs(tab) do
		dest[k] = v
	end
	return dest
end

function vdef_mt.__mul(left, right)
	if type(right) == "table" then
		left, right = right, left
	end

	local ret = paste({}, left)

	if type(right) == "string" then
		ret.type = right
	else
		paste(ret, right)
	end

	return vdef(ret)
end

vdef_mt.__add = vdef_mt.__mul

local function defvar(name, def)
	local d = {name = name}
	if type(def) == "string" then
		d.type = def
	else
		paste(d, def)
	end

	_vars[name] = d
end

env.define.var = namespace(defvar)

env.define.vars = function(vd, defs)
	if not defs then return env.define.vars(nil, vd) end

	if vd then
		for _,name in ipairs(defs) do
			defvar(name, vd)
		end
	else
		for k,v in pairs(defs) do
			if type(k) == "number" then
				defvar(v, "real")
			else
				defvar(k, v)
			end
		end
	end
end

env.read.cost = function(fname)
	local costs = read_json(fname)

	for k,v in pairs(costs) do
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

--------------------------------------------------------------------------------

return env, {
	calib = calib,
	types = types,
	models = models,
	vars = vars
}
