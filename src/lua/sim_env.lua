local simenv_mt = { __index = {} }

local function create(sim)
	return setmetatable({
		env = setmetatable({}, {__index=_G}),
		sim = sim
	}, simenv_mt)
end

local function from_conf(cfg)
	local sim = require("sim").create()
	local ret = create(sim)

	local fhk = require("fhk")
	local mapper = fhk.hook(fhk.build_graph(cfg.fhk_vars, cfg.fhk_models))
	mapper:create_models(cfg.calib)

	ret:inject_base()
	ret:inject_fhk(mapper)
	ret:inject_types(cfg)

	return ret
end

function simenv_mt.__index:inject_base()
	require("sim").inject(self.env, self.sim)
	require("world").inject(self.env, self.sim._sim)
	require("typing").inject(self.env)
end

function simenv_mt.__index:inject_fhk(mapper)
	require("fhk").inject(self.env, mapper)
end

function simenv_mt.__index:inject_types(cfg)
	self.env.enum = {}
	for name,e in pairs(cfg.enums) do
		self.env.enum[name] = e.values
	end

	self.env.types = cfg.types
end

function simenv_mt.__index:run_file(fname)
	local f, err = loadfile(fname, nil, self.env)
	if err then
		error(err)
	end
	return f()
end

function simenv_mt.__index:simulate(rec)
	self:prepare()
	self.sim:simulate(rec)
end

function simenv_mt.__index:prepare()
	if not self._prepared then
		self._prepared = true
		self.sim:event("sim:prepare")
	end
end

function simenv_mt.__index:setup(data)
	self.sim:event("sim:setup", data)
end

return {
	create    = create,
	from_conf = from_conf
}
