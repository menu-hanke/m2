local fhk = require "fhk"
local env = require "env"
local misc = require "misc"

local sandbox = {}

local function init_sandbox(path, loaded)
	sandbox.path = path
	sandbox.loaded = loaded
	sandbox.loaded.ffi = require("ffi")
end

local simenv_mt = { __index = {} }

local function create(sim)
	local m2 = {}
	return setmetatable({
		-- put the 'm2' module as both in _loaded (proxy for package.loaded) and the global 'm2'.
		-- this is intentional and the same behavior as luajit does with the 'jit' module.
		env = setmetatable({ m2=m2 }, {__index=_G}),
		m2  = m2,
		sim = sim
	}, simenv_mt)
end

function simenv_mt.__index:inject_env()
	-- low-effort "sandbox"
	-- Not a sandbox in any security sense, just to give a bit of isolation to scripts,
	-- and automatically give them the sim environment (ie. the m2 global)
	--
	-- Note that scripts may still break each other or the simulator, eg. by modifying built-ins
	-- like string or math
	
	self.env.package = misc.merge({}, package)
	self.env.package.loaded = misc.merge({m2=self.m2}, sandbox.loaded)
	self.env.package.path = sandbox.path
	self.env.require = misc.delegate(self, self.require)
end

function simenv_mt.__index:inject_base()
	require("sim").inject(self)
	require("kernel").inject(self)
	require("data").inject(self)
	require("soa").inject(self)
	require("typing").inject(self)
	require("sched").inject(self)
	require("vmath").inject(self)
end

function simenv_mt.__index:inject_fhk(def)
	require("fhk").inject(self, def)
end

local function sandbox_require(env, module)
	local package = env.package
	local err = {}

	for _,ld in ipairs(package.loaders) do
		local f = ld(module)
		if type(f) == "function" then
			-- don't break env for libraries
			-- TODO: remove this check and instead write a custom loader that checks for
			-- local files (like the package.path loader) and sets the env
			if getfenv(f) == _G and debug.getinfo(f).what ~= "C" then
				setfenv(f, env)
			end
			local m = f(module)
			if m == nil then
				m = true
			end

			package.loaded[module] = m
			return m
		elseif f then
			table.insert(err, f)
		end
	end

	error(string.format("Module '%s' not found: %s", module, table.concat(err, "\n")))
end

-- replace require so that sim modules automagically have sim environment
function simenv_mt.__index:require(module, global)
	if global then
		return require(module)
	end

	local mod = self.env.package.loaded[module]
	if mod then
		return mod
	end

	-- XXX: this is an awkward way to do it, hovewer the functions in package.loaders read
	-- the path/cpath from their (C) environment, so there is no good way to change it.
	-- ie. we _must_ change the actual package.path.
	-- ie. we must set it, then load, then restore it.
	-- Note: this doesn't prevent the script from modifying eg. package.loaders but it should
	-- cover most cases
	local path, cpath = package.path, package.cpath
	package.path = self.env.package.path
	package.cpath = self.env.package.cpath
	local ok, r = xpcall(sandbox_require, debug.traceback, self.env, module)
	package.path = path
	package.cpath = cpath

	if ok then
		return r
	end

	error(r, 2)
end

function simenv_mt.__index:require_all(modules)
	for i,mod in ipairs(modules) do
		self:require(mod)
	end
end

function simenv_mt.__index:run_file(fname)
	local f, err = loadfile(fname, nil, self.env)
	if err then
		error(err)
	end
	return f()
end

--------------------------------------------------------------------------------

local envconf_mt = { __index={} }

local function envconf()
	return setmetatable({
		modules = {}
	}, envconf_mt)
end

function envconf_mt.__index:fhk_def()
	if not self._fhk_def then
		self._fhk_def = fhk.def()
	end

	return self._fhk_def
end

function envconf_mt.__index:module(module)
	table.insert(self.modules, module)
end

local function conf_env(conf)
	local fhk_env

	local cenv = setmetatable({
		sim   = misc.delegate(conf, conf.module),
		graph = function(fname)
			fhk_env = fhk_env or fhk.def_env(conf:fhk_def())
			fhk_env.read(fname)
		end
	}, { __index=_G })

	cenv.read = function(fname) return env.read(cenv, fname) end
	return cenv
end

local function from_conf(conf)
	local sim = require("sim").create()
	local env = create(sim)

	env:inject_env()
	env:inject_base()

	if conf._fhk_def then
		env:inject_fhk(conf._fhk_def)
	end

	env:require_all(conf.modules)
	return env
end

local function exists(fname)
	local fp = io.open(fname)
	if fp then
		io.close(fp)
		return true
	end
end

local function from_cmdline(cfname)
	local conf = envconf()
	local cenv = conf_env(conf)

	cfname = cfname or (exists("Melasim.lua") and "Melasim.lua")
	if cfname then
		cenv.read(cfname)
	end

	return from_conf(conf)
end

--------------------------------------------------------------------------------

return {
	init_sandbox = init_sandbox,
	create       = create,
	conf         = envconf,
	conf_env     = conf_env,
	from_conf    = from_conf,
	from_cmdline = from_cmdline
}
