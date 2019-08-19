local ffi = require "ffi"
local conf = require "conf"
local sim = require "sim"
local world = require "world"
local fhk = require "fhk"

local function envtable(mes)
	return setmetatable({}, {__index=function(_, name)
		error(string.format(mes, name))
	end})
end

local function create_metatables(env)
	env._obj_meta = { __index={} }
	env._var_meta = { __index={} }
	env._env_meta = { __index={} }
end

local function inject_types(env, cfg)
	local enum = {}
	env.enum = enum

	for name,t in pairs(cfg.types) do
		if t.kind == "enum" then
			enum[name] = t.def
		end
	end
end

local function inject_names(env, cfg)
	env.obj = envtable("No object with name '%s'")
	env.id  = envtable("No varid with name '%s'")
	env.var = envtable("No fhk var with name '%s'")
	env.env = envtable("No env with name '%s'")

	for name,obj in pairs(cfg.objs) do
		env.obj[name] = setmetatable(obj, env._obj_meta)
		for vname,var in pairs(obj.vars) do
			env.id[vname] = var.varid
		end
	end

	for name,fv in pairs(cfg.fhk_vars) do
		env.var[name] = setmetatable(fv, env._var_meta)
	end

	for name,e in pairs(cfg.envs) do
		env.env[name] = setmetatable(e, env._env_meta)
	end
end

local function main(args)
	if not args.scripts then
		error("No scripts given, give some with -s")
	end

	local cfg = conf.read(args.config)
	local _sim = sim.create()
	local _world = world.create(_sim._sim)
	world.define(cfg, _world)
	local G = fhk.create_graph(cfg)
	fhk.create_exf(cfg)
	local ugraph = fhk.create_ugraph(G, cfg)

	local env = setmetatable({}, {__index=_G})
	create_metatables(env)
	sim.inject(env, _sim)
	world.inject(env, _world)
	fhk.inject(env, cfg, G, ugraph)
	inject_types(env, cfg)
	inject_names(env, cfg)

	for _,s in ipairs(args.scripts) do
		local f, err = loadfile(s, nil, env)
		if err then
			error(err)
		end
		f()
	end
end

return { main=main }
