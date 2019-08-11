local ffi = require "ffi"
local conf = require "conf"
local sim = require "sim"
local world = require "world"
local fhk = require "fhk"

local function inject_types(env, cfg)
	local enum = {}
	env.enum = enum

	for name,t in pairs(cfg.types) do
		if t.kind == "enum" then
			enum[name] = t.def
		end
	end
end

local function inject_fhk(env, cfg, world)
	local G = conf.create_fhk_graph(cfg)
	local u = fhk.create_ugraph(G, cfg)
	u:add_world(cfg, world)
	local _world = world._world

	env.uset_obj = function(objname, varids)
		return u:obj_uset(u.obj[objname], _world, varids)
	end

	env.fhk_update = delegate(u, u.update)
end

local function main(args)
	if not args.scripts then
		error("No scripts given, give some with -s")
	end

	local data = conf.read(get_builtin_file("builtin_lex.lua"), args.config)
	local lex = conf.create_lexicon(data)
	local _sim = sim.create()
	local _world = world.create(_sim._sim, lex)
	local env = setmetatable({}, {__index=_G})
	inject_types(env, data)
	inject_fhk(env, data, _world)
	sim.inject(env, _sim)
	world.inject(env, _world)

	for _,s in ipairs(args.scripts) do
		local f, err = loadfile(s, nil, env)
		if err then
			error(err)
		end
		f()
	end
end

return { main=main }
