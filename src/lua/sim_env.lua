local aux = require "aux"

local sandbox = {}

local function init_sandbox(path, loaded)
	sandbox.path = path
	sandbox.loaded = loaded
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

local function from_conf(cfg)
	local sim = require("sim").create()
	local env = create(sim)

	local fhk = require("fhk")
	local mapper = fhk.hook(fhk.build_graph(cfg.fhk_vars, cfg.fhk_models))
	mapper:bind_models(fhk.create_models(cfg.fhk_vars, cfg.fhk_models, cfg.calib))

	env:inject_env()
	env:inject_base()
	env:inject_fhk(mapper)
	env:inject_types(cfg)

	for _,modname in pairs(cfg.modules) do
		env:require(modname)
	end

	return sim, env
end

function simenv_mt.__index:inject_env()
	-- low-effort "sandbox"
	-- Not a sandbox in any security sense, just to give a bit of isolation to scripts,
	-- and automatically give them the sim environment (ie. the m2 global)
	--
	-- Note that scripts may still break each other or the simulator, eg. by modifying built-ins
	-- like string or math
	
	self.env.package = aux.merge({}, package)
	self.env.package.loaded = aux.merge({m2=self.m2}, sandbox.loaded)
	self.env.package.path = sandbox.path
	self.env.require = aux.delegate(self, self.require)
end

function simenv_mt.__index:inject_base()
	require("sim").inject(self)
	require("globals").inject(self)
	require("vec").inject(self)
	require("typing").inject(self)
	require("sched").inject(self)
	require("vmath").inject(self)
end

function simenv_mt.__index:inject_fhk(mapper)
	self.mapper = mapper
	require("fhk").inject(self)
end

function simenv_mt.__index:inject_types(cfg)
	local masks = {}
	for name,e in pairs(cfg.enums) do
		masks[name] = e.values
	end

	self.m2.masks = masks
	self.m2.types = cfg.types
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
	local ok, r = pcall(sandbox_require, self.env, module)
	package.path = path
	package.cpath = cpath

	if ok then
		return r
	end

	error(r)
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

function simenv_mt.__index:setup(data)
	self.sim:event("sim:setup", data)
end

return {
	init_sandbox = init_sandbox,
	create       = create,
	from_conf    = from_conf
}
