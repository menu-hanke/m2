local conv = require "model.conv"
local model = require "model"
local misc = require "misc"
local ffi = require "ffi"
local C = ffi.C

-- this is the frontend graph definition, not an fhk graph def.
-- in particular, this contains only models. variables come from the simulator
-- (ie. only the models with computable variables will be chosen for the simulation).

local gdef_mt = { __index = {} }
local gmod_mt = { __index = {k=1, c=1.5} }
local link_mt = { __index = {astype = conv.typemask()}}

local function gdef()
	return setmetatable({
		models = {},
		costs  = {},
		calibs = {},
		labels = {}
	}, gdef_mt)
end

function gdef_mt.__index:model(name, attr)
	if self.models[name] then
		error(string.format("Duplicate definition of model '%s'", name))
	end

	local mod = setmetatable({
		name    = name,
		params  = {},
		returns = {},
		checks  = {}
	}, gmod_mt)

	for _,a in ipairs(attr) do
		a(mod)
	end

	self.models[name] = mod
	return mod
end

function gmod_mt.__index:add_param(target, subset, astype)
	table.insert(self.params, setmetatable({
		target = target or error(string.format("%s: missing parameter name", self.name)),
		subset = subset,
		astype = astype
	}, link_mt))
end

function gmod_mt.__index:add_return(target, subset, astype)
	table.insert(self.returns, setmetatable({
		target = target or error(string.format("%s: missing return name", self.name)),
		subset = subset,
		astype = astype
	}, link_mt))
end

function gmod_mt.__index:add_check(target, subset, constraint, name)
	table.insert(self.checks, {
		target     = target or error(string.format("%s: missing check target")),
		subset     = subset,
		create_constraint = constraint or error(string.format("%s: missing check constraint (%s)", self.name, target)),
		name       = name,
		penalty    = math.huge -- TODO
	})
end

function gmod_mt.__index:check()
	if not self.impl then error(string.format("%s: missing impl", self.name)) end
	if #self.returns == 0 then error(string.format("%s: model doesn't return anything", self.name)) end
end

function gdef_mt.__index:copylabels(lab)
	for name,l in pairs(lab) do
		if self.labels[name] and self.labels[name] ~= l then
			error(string.format("Redefinition of label '%s': %s -> %s", name, self.labels[name], l))
		end
		self.labels[name] = l
	end
end

function gdef_mt.__index:L(x)
	if type(x) == "table" then
		local ret = {}
		for k,v in pairs(x) do
			ret[k] = self:L(v)
		end
		return ret
	end

	return self.labels[x] or error(string.format("Undefined label: '%s'", x))
end

function gdef_mt.__index:set_constraint(val, inverse)
	val = type(val) ~= "table" and {val} or val

	return function(cst, typ)
		local mask = 0ULL

		for i,v in ipairs(val) do
			v = type(v) == "number" and v or self:L(v)
			if type(v) ~= "number" or v < 0 or v >= 64 then
				error(string.format("not a valid bit: %s", v))
			end
			mask = bit.bor(mask, bit.lshift(1ULL, v))
		end

		if inverse then
			mask = bit.bnot(mask)
		end

		if typ == C.MT_UINT8 then
			cst:set_u8_mask64(mask)
		else
			error(string.format("set constraint isn't applicable to %s", conv.nameof(typ)))
		end
	end
end

function gdef_mt.__index:fp_constraint(x, cmp)
	if cmp == "<" or cmp == ">" then
		error("TODO (use nextafter and ge/le constraint)")
	end

	return function(cst, typ)
		if typ == C.MT_FLOAT then
			cst:set_cmp_fp32(cmp, x)
		else
			assert(typ == C.MT_DOUBLE)
			cst:set_cmp_fp64(cmp, x)
		end
	end
end

local function apply_edges(f, x)
	if type(x) == "string" then
		f({target=x})
		return
	end

	-- it's of the form {target="...", subset="...", ...}
	if #x == 0 then
		f(x)
		return
	end

	-- it's a nested list eg. params { "...", { ... } }
	for i,e in ipairs(x) do
		apply_edges(f, e)
	end
end

local edgef_mt = {
	__call = function(self, mod)
		apply_edges(function(e) self._apply(mod, e, self) end, self._edges)
	end
}

local function edge_f(f)
	return function(x)
		return setmetatable({_apply=f, _edges=x}, edgef_mt)
	end
end

local function toedge(x)
	return type(x) == "string" and {target=x} or x
end

local function modifier(f)
	return setmetatable({}, {
		__mul = function(x)
			return f(toedge(x))
		end
	})
end

local function cst_modifier(cst)
	return modifier(function(x)
		x.constraint = cst
		return x
	end)
end

local gdef_func = setmetatable({
	params = edge_f(function(mod, edge, defaults)
		mod:add_param(edge.target,
			edge.subset or defaults.subset,
			edge.astype or defaults.astype
		)
	end),

	returns = edge_f(function(mod, edge, defaults)
		mod:add_return(edge.target,
			edge.subset or defaults.subset,
			edge.astype or defaults.astype
		)
	end),

	check = edge_f(function(mod, edge, defaults)
		mod:add_check(edge.target,
			edge.subset or defaults.subset,
			edge.constraint or defaults.constraint
		)
	end),

	-- TODO: allow reading costs from file
	cost = function(kc)
		return function(mod)
			mod.k = kc.k
			mod.c = kc.c
		end
	end,

	set = function(def)
		return modifier(function(x)
			x.subset = def
			return x
		end)
	end,

	as = function(typ)
		typ = conv.typemask(typ)
		return modifier(function(x)
			x.astype = typ
			return x
		end)
	end,

	impl = setmetatable({}, {
		__index = function(self, name)
			local def = model.lang(name).def
			self[name] = function(...)
				local args = {...}
				return function(model)
					model.impl = def(unpack(args))
				end
			end
			return self[name]
		end
	})
}, {__index=_G})

-- this gives a dsl-like environment that can be used in config files
local function gdef_env(def)
	local env = setmetatable({

		model = function(name)
			return function(attrs)
				def:model(name, attrs):check()
			end
		end,

		derive = function(x)
			return function(attrs)
				local name = type(x) == "string" and x or x.target
				local mod = def:model(name, attrs)
				mod.k = 0
				mod.c = 1
				if #mod.returns == 0 then
					gdef_func.returns(x)(mod)
				end
				if #mod.checks > 0 then
					error(string.format("model '%s' of derived var can't contain checks", name))
				end
				mod:check()
			end
		end,

		is = function(cst) return cst_modifier(def:set_constraint(cst)) end,
		is_not = function(cst) return cst_modifier(def:set_constraint(cst, true)) end,
		ge = function(x) return cst_modifier(def:fp_constraint(x, ">=")) end,
		gt = function(x) return cst_modifier(def:fp_constraint(x, ">")) end,
		le = function(x) return cst_modifier(def:fp_constraint(x, "<=")) end,
		lt = function(x) return cst_modifier(def:fp_constraint(x, "<")) end

	}, { __index=gdef_func })

	env.read = function(fname) return misc.dofile_env(env, fname) end
	return env
end

local function read(...)
	local def = gdef()
	local env = gdef_env(def)

	for _,f in ipairs({...}) do
		env.read(f)
	end

	return def
end

return {
	create  = gdef,
	env     = gdef_env,
	read    = read
}
