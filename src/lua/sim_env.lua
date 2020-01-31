local aux = require "aux"

local simenv_mt = { __index = {} }

local function create(sim)
	local m2 = {}
	return setmetatable({
		-- put the 'm2' module as both in _loaded (proxy for package.loaded) and the global 'm2'.
		-- this is intentional and the same behavior as luajit does with the 'jit' module.
		env = setmetatable({ _loaded={m2=m2}, m2=m2 }, {__index=_G}),
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

-- replace require so that sim modules automagically have sim environment
function simenv_mt.__index:require(module, global)
	if global then
		return require(module)
	end

	if self.env._loaded[module] ~= nil then
		return self.env._loaded[module]
	end

	local err = {}

	for _,ld in ipairs(self.env.package.loaders) do
		local f = ld(module)
		if type(f) == "function" then
			setfenv(f, self.env)
			local m = f(module)
			if m == nil then
				m = true
			end

			self.env._loaded[module] = m
			return m
		elseif f then
			table.insert(err, f)
		end
	end

	error(string.format("Module '%s' not found: %s", module, table.concat(err, "\n")))
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
	create    = create,
	from_conf = from_conf
}
