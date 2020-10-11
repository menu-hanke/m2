local misc = require "misc"
local cli = require "cli"
local sim_env = require "sim_env"
local log = require("log").logger

local function main(args)
	local env = sim_env.from_cmdline(args.config)
	env:require_all(args.scripts or {})
	env:prepare()

	if args.instr then
		local insn = env:load_insn(args.instr)

		if args.input then
			local sim = env.sim
			local data = misc.readjson(args.input)
			sim:savepoint()
			local fp = sim:fp()
			for i,v in ipairs(data) do
				log:verbose("[%s] %d/%d", args.input, i, #data)
				sim:enter()
				env:event("sim:setup", v)
				insn()
				sim:load(fp)
			end
		else
			insn()
		end
	else
		-- this is only for debugging
		env:event("sim:main")
	end
end

return {
	cli_main = {
		main = main,
		usage = "[instructions] [-i input] [-c config] [-s scripts]...",
		flags = {
			cli.positional("instr"),
			cli.opt("-i", "input"),
			cli.opt("-c", "config"),
			cli.opt("-s", "scripts", "multiple")
		}
	}
}
