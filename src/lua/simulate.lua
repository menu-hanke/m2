local ffi = require "ffi"
local conf = require "conf"
local sim = require "sim"
local world = require "world"
local fhk = require "fhk"

local function main(args)
	if not args.scripts then
		error("No scripts given, give some with -s")
	end

	local data = conf.read(get_builtin_file("builtin_lex.lua"), args.config)
	local lex = conf.create_lexicon(data)
	--local G = conf.create_fhk_graph(data)
	--fhk.init_fhk_graph(G)
	local _sim = sim.create()
	local _world = world.create(_sim._sim, lex)
	local env = setmetatable({}, {__index=_G})
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
