local simenv_mt = { __index = {} }

local function create(sim)
	return setmetatable({
		env = setmetatable({ _loaded={} }, {__index=_G}),
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

function simenv_mt.__index:inject(name, value)
	self.env[name] = value
end

function simenv_mt.__index:inject_env()
	self.env.require = delegate(self, self.require)
end

function simenv_mt.__index:inject_base()
	require("sim").inject(self.env, self.sim)
	require("globals").inject(self.env, self.sim._sim)
	require("vec").inject(self.env, self.sim._sim)
	require("typing").inject(self.env)
	require("sched").inject(self.env)
	require("vmath").inject(self.env, self.sim)
end

function simenv_mt.__index:inject_fhk(mapper)
	self.mapper = mapper
	require("fhk").inject(self.env, mapper)
end

function simenv_mt.__index:inject_types(cfg)
	self.env.enum = {}
	for name,e in pairs(cfg.enums) do
		self.env.enum[name] = e.values
	end

	self.env.types = cfg.types
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
