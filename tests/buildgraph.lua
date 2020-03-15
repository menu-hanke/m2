local ffi = require "ffi"
local fhk = require "fhk"
local fhkdbg = require "fhkdbg"
local typing = require "typing"

local function vsetdefault(vars, name)
	vars[name] = vars[name] or { ptype = typing.pvalues.real }
end

local function collect(def)
	local vars, models, values = {}, {}, {}

	for i,x in ipairs(def) do
		if x.kind == "model" then
			models[x.name] = x
		else
			x.ptype = typing.pvalues[x.type or "real"]
			vars[x.name] = x
			if x.value then
				values[x.name] = x.value
			end
		end
	end

	for _,m in pairs(models) do
		for c,_ in pairs(m.checks) do vsetdefault(vars, c) end
		for _,p in ipairs(m.params) do vsetdefault(vars, p) end
		for _,r in ipairs(m.returns) do vsetdefault(vars, r) end
	end

	return vars, models, values
end

local function rep(v, n)
	local ret = {}
	for i=1, n do
		ret[i] = v
	end
	return ret
end

local function make_exf(g, models)
	for name,m in pairs(models) do
		local f = m.f
		if type(f) ~= "function" then
			local data = type(f) == "number" and rep(f, #m.returns) or f
			f = function() return unpack(data) end
		end
		g:exf(name, f)
	end
end

local function build(def)
	local vars, models, values = collect(def)
	local g = fhkdbg.hook(fhk.build_graph(vars, models))
	make_exf(g, models)
	return g, vars, models, values
end

local function impl(models, impls)
	for name,m in pairs(models) do
		m.impl = m.impl or impls[name]
			or {lang="Const", opt={ret=type(m.f)=="number" and rep(m.f, #m.returns) or m.f}}
	end
end

local function mapper(opt)
	local vars, models = collect(opt.graph)
	impl(models, opt.impl or {})
	local mp = fhk.hook(fhk.build_graph(vars, models))
	mp:bind_models(fhk.create_models(vars, models, opt.calib))
	return mp
end

--------------------------------------------------------------------------------

local mdef_mt = { __index={ kind="model" } }

local function mdef(name, f)
	return setmetatable({
		name    = name,
		params  = {},
		returns = {},
		checks  = {},
		coeffs  = {},
		f       = type(f) == "number" and {f} or f or 0,
		k       = 1,
		c       = 1
	}, mdef_mt)
end

function mdef_mt.__index:cost(cost)
	if type(c) == "number" then
		self.k = cost
	else
		self.k = cost.k or cost[1] or self.k
		self.c = cost.c or cost[2] or self.c
	end
	return self
end

function mdef_mt.__index:par(params)
	self.params = type(params) == "table" and params or {params}
	return self
end

function mdef_mt.__index:ret(returns)
	self.returns = type(returns) == "table" and returns or {returns}
	return self
end

function mdef_mt.__index:check(check)
	self.checks[check.var] = check
	return self
end

-- shortcut operators for less typing
mdef_mt.__mod = mdef_mt.__index.check -- m % check
mdef_mt.__mul = mdef_mt.__index.cost  -- m * cost
mdef_mt.__add = mdef_mt.__index.par   -- m + params
mdef_mt.__lt  = mdef_mt.__index.ret   -- m > returns
mdef_mt.__sub = mdef_mt.__index.ret   -- m - returns  (for cases when return is not table)

local check_mt = { __index={} }

local function check(x, cost)
	x.cost_in = cost.m or 0
	x.cost_out = cost.M or math.huge
	return setmetatable(x, check_mt)
end

function check_mt.__pow(left, right)  -- "var"^check
	if type(right) == "string" then
		left, right = right, left
	end
	right.var = left
	return right
end

local function bmask(x)
	local ret = 0ULL
	for _,v in ipairs(x) do
		ret = bit.bor(ret, bit.lshift(1ULL, v))
	end
	return ret
end

local function any(x) return check({type="set", mask=bmask(x)}, x) end
local function none(x) return check({type="set", mask=bit.bnot(bmask(x))}, x) end
local function ival(x) return check({type="interval", a=x[1] or -math.huge, b=x[2] or math.huge},x) end

--------------------------------------------------------------------------------

local vdef_mt = { __index={ kind="var" } }

local function vdef(name, value)
	return setmetatable({ name=name, value=value }, vdef_mt)
end

function vdef_mt.__index:typ(t)
	self.type = t
	return self
end

vdef_mt.__pow = vdef_mt.__index.typ  -- v ^ type

--------------------------------------------------------------------------------

return {
	collect = collect,
	build   = build,
	impl    = impl,
	mapper  = mapper,
	m       = mdef,
	v       = vdef,
	any     = any,
	none    = none,
	ival    = ival
}
