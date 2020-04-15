local misc = require "misc"
local cli = require "cli"
local sim_env = require "sim_env"
local log = require("log").logger

local function main(args)
	local env = sim_env.from_cmdline(args.config)
	env:require_all(args.scripts or {})

	local sim = env.sim
	sim:compile()

	if args.instr then
		local instr = env:run_file(args.instr)
		instr = sim:compile_instr(instr)

		if args.input then
			local data = misc.readjson(args.input)
			sim:savepoint()
			for i,v in ipairs(data) do
				log:verbose("[%s] %d/%d", args.input, i, #data)
				sim:enter()
				sim:event("sim:setup", v)
				sim:simulate(instr)
				sim:exit()
				sim:restore()
			end
		else
			sim:simulate(instr)
		end
	else
		-- this is only for debugging
		sim:event("sim:main")
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
