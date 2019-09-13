local conf = require "conf"
local sim = require "sim"
local world = require "world"
local typing = require "typing"
local fhk = require "fhk"

local function inject_types(env, cfg)
	env.enum = {}
	for name,e in pairs(cfg.enums) do
		env.enum[name] = e.values
	end

	env.types = cfg.types
end

local function main(args)
	if not args.scripts then
		error("No scripts given, give some with -s")
	end

	local cfg = conf.read(args.config)
	local _sim = sim.create()
	local mapper = fhk.hook(fhk.build_graph(cfg.fhk_vars, cfg.fhk_models))
	mapper:create_models(cfg.calib)

	local env = setmetatable({}, {__index=_G})
	sim.inject(env, _sim)
	typing.inject(env)
	fhk.inject(env, mapper)
	world.inject(env, _sim._sim)
	inject_types(env, cfg)

	for _,s in ipairs(args.scripts) do
		local f, err = loadfile(s, nil, env)
		if err then
			error(err)
		end
		f()
	end
end

return { main=main }
