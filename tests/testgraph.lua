local fhk = require "fhk"
local fhkdbg = require "fhkdbg"
local misc = require "misc"
local ffi = require "ffi"

local function topvalue(x)
	if ffi.istype("pvalue", x) then
		return x
	end

	local ret = ffi.new("pvalue")

	if type(x) == "number"           then ret.f64 = x
	elseif ffi.istype("uint64_t", x) then ret.u64 = x
	else assert(false)
	end

	return ret
end

--------------------------------------------------------------------------------

local mdef_mt = { __index={} }

local function parsemodel(def)
	def = def:gsub("%s", "")

	-- name:params->returns
	local name, params, returns = def:match("^([^:]+):(.-)%->(.*)$")
	if name then
		return name, params, returns
	end

	-- params->returns
	local params, returns = def:match("^(.-)%->(.*)$")
	if params then
		return def, params, returns
	end

	error(string.format("model syntax error: %s", def))
end

local function isimpl(f)
	return (type(f) == "string" or (type(f) == "table" and f.lang)) and f
end

local function m(def, f)
	local name, params, returns = parsemodel(def)

	return setmetatable({
		name    = name,
		params  = misc.split(params),
		returns = misc.split(returns),
		checks  = {},
		coeffs  = {},
		impl    = isimpl(f),
		_impl   = f,
		_cost   = { checks={} }
	}, mdef_mt)
end

function mdef_mt.__index:check(cs)
	misc.merge(self.checks, cs)
	return self
end

function mdef_mt.__index:cost(cst)
	misc.merge(self._cost, cst)
	return self
end

function mdef_mt.__index:xcost(cst)
	for name,xc in pairs(cst) do
		self._cost.checks[name] = { cost_in=xc[1], cost_out=xc[2] }
	end
	return self
end

function mdef_mt.__index:coef(names)
	misc.merge(self.coeffs, names)
	return self
end

function mdef_mt.__index:define(def)
	def:model(self.name, self)
	def:cost(self.name, self._cost)
end

function mdef_mt.__index:inject_debugger(debugger)
	local impl = self._impl
	local nret = #self.returns

	if type(impl) == "function" then
		local narg = #self.params

		debugger.models[self.name] = function(ret, args)
			local a = {}
			for i=1, narg do
				a[i] = args[i-1]
			end

			local r = {impl(unpack(a))}

			for i,x in ipairs(r) do
				ret[i-1] = topvalue(x)
			end
		end
	elseif impl then
		local r = ffi.new("pvalue[?]", nret)
		if type(impl) == "table" then
			for i,x in ipairs(impl) do
				r[i-1] = topvalue(x)
			end
		else
			r[0] = topvalue(impl)
		end

		debugger.models[self.name] = function(ret)
			ffi.copy(ret, r, nret * ffi.sizeof("pvalue"))
		end
	else
		debugger.models[self.name] = function()
			error(string.format("this model shouldn't be called: %s", self.name))
		end
	end
end

--------------------------------------------------------------------------------

local hdef_mt = { __index={} }

local function h(hints)
	return setmetatable({hints=hints}, hdef_mt)
end

function hdef_mt.__index:define(def)
	for name,hint in pairs(self.hints) do
		def:hint(name, hint)
	end
end

function hdef_mt.__index:inject_debugger()
end

--------------------------------------------------------------------------------

local function solution(xs)
	return function(dbg, ok)
		if not ok then error(dbg:error()) end

		for name,x in pairs(xs) do
			local v = dbg:read(name)
			x = topvalue(x)

			if v.u64 ~= x.u64 then
				error(string.format("%s: %f/%s != %f/%s", name, v.f64, v.u64, x.f64, x.u64))
			end
		end
	end
end

local function samegraph(names)
	local ns = {}
	for _,name in ipairs(names) do
		ns[name] = true
	end

	return function(dbg, ok, vars, models)
		if not ok then error(dbg:error()) end

		local subgraph = {}

		for _,v in ipairs(vars) do
			if not ns[v] then
				error(string.format("Reduced graph is not subgraph: var '%s' is missing", v))
			end
			subgraph[v] = true
		end

		for _,m in ipairs(models) do
			if not ns[m] then
				error(string.format("Reduced graph is not subgraph: model '%s' is missing", m))
			end
			subgraph[m] = true
		end

		for _,name in ipairs(names) do
			if not subgraph[name] then
				error(string.format("Given graph is not subgraph: name '%s' is missing", name))
			end
		end
	end
end

local function failure(how)
	how = how or {}

	return function(dbg, ok)
		if ok then error("expected failure") end
		if how.err and dbg.G.last_error.err ~= how.err then
			error(string.format("err: %d != %d", dbg.G.last_error.err, how.err))
		end
	end
end

--------------------------------------------------------------------------------

local defgraph_mt = { __index = {} }

local function defgraph(ondef)
	return setmetatable({ondef=ondef}, defgraph_mt)
end

function defgraph_mt.__index:lazy_def()
	self._def = self._def or fhk.def()
	return self._def
end

function defgraph_mt.__index:clear_def()
	self._def = nil
end

function defgraph_mt.__index:graph(ms)
	local def = self:lazy_def()

	for _,m in ipairs(ms) do
		m:define(def)
	end

	self.ondef(def, ms)
	self:clear_def()
end

function defgraph_mt.__index:inject(env)
	env.m = m
	env.h = h
	env.graph = misc.delegate(self, self.graph)
	env.any = function(...) return self:lazy_def():any(...) end
	env.none = function(...) return self:lazy_def():none(...) end
	env.between = function(...) return self:lazy_def():between(...) end
end

local testgraph_mt = { __index={} }

local function testgraph(def, ms)
	local debugger = fhkdbg.debugger(nil, fhk.build_graph(def))

	for _,m in ipairs(ms) do
		m:inject_debugger(debugger)
	end

	return setmetatable({
		_debugger = debugger
	}, testgraph_mt)
end

function testgraph_mt.__index:given(xs)
	for name,x in pairs(xs) do
		if type(name) == "string" then
			self._debugger:given(name, type(x) == "function" and x or topvalue(x))
		else
			self._debugger:given(x)
		end
	end
end

function testgraph_mt.__index:want(names)
	self._want = names
end

function testgraph_mt.__index:solution(check)
	local names

	if type(check) == "table" then
		names = misc.keys(check)
		check = solution(check)
	else
		names = self._want
	end

	check(self._debugger, self._debugger:solve(names))
	self._debugger:reset()
end

function testgraph_mt.__index:reduces(check)
	if type(check) == "table" then
		check = samegraph(check)
	end

	check(self._debugger, self._debugger:reduce(self._want))
	self._debugger:reset()
end

function testgraph_mt.__index:inject(env)
	env.given = misc.delegate(self, self.given)
	env.want = misc.delegate(self, self.want)
	env.solution = misc.delegate(self, self.solution)
	env.reduces = misc.delegate(self, self.reduces)
	env.failure = failure
end

--------------------------------------------------------------------------------

return {
	injector = function(ondef)
		return function(env)
			local env = env or setmetatable({}, {__index=_G})
			defgraph(function(graph, ms) ondef(graph, ms, env) end):inject(env)
			return env
		end
	end,

	inject_test = function(graph, ms, env)
		testgraph(graph, ms):inject(env)
	end,

	m = m,
	h = h
}
