local aux = require "aux"
local cli = require "cli"
local conf = require "conf"
local sim_env = require "sim_env"
local log = require("log").logger

local function main(args)
	local cfg = conf.read_cmdline(args.config)
	local sim, env = sim_env.from_conf(cfg)
	env:require_all(args.scripts or {})
	local instr = env:run_file(args.instr or "instr.lua")

	sim:compile()
	instr = sim:compile_instr(instr)

	if args.input then
		local data = aux.readjson(args.input)
		sim:savepoint()
		for i,v in ipairs(data) do
			log:verbose("[%s] %d/%d", args.input, i, #data)
			sim:enter()
			env:setup(v)
			sim:simulate(instr)
			sim:exit()
			sim:restore()
		end
	else
		sim:simulate(instr)
	end
end

return {
	cli_main = {
		main = main,
		usage = "[instructions] [input] [-c config] [-s scripts]...",
		flags = {
			cli.positional("instr"),
			cli.opt("-i", "input"),
			cli.opt("-c", "config"),
			cli.opt("-s", "scripts", "multiple")
		}
	}
}
