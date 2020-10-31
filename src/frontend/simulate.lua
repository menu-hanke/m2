local misc = require "misc"
local cli = require "cli"
local sim_env = require "sim_env"
local log = require("log").logger

local DEFAULT_FRAMES = 16
local DEFAULT_RSIZE  = 20

local function main(args)
	local env = sim_env.from_cmdline(args.config, {
		nframes = tonumber(args.nframes) or DEFAULT_FRAMES,
		rsize   = 2 ^ (tonumber(args.rsize) or DEFAULT_RSIZE)
	})

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
		usage = string.format([[[instructions] [options]...

    Arguments:
        instructions     Instruction file

    Options:
        -F nframes       Allocate {nframes} frames (default: %d)
        -R rsize         Allocate 2^{rsize}-sized regions (default: 2^%d)
        -i input         Input file
        -c config        Config file
        -s script        Additional scripts
]], DEFAULT_FRAMES, DEFAULT_RSIZE),
		flags = {
			cli.positional("instr"),
			cli.opt("-F", "nframes"),
			cli.opt("-R", "rsize"),
			cli.opt("-i", "input"),
			cli.opt("-c", "config"),
			cli.opt("-s", "scripts", "multiple")
		}
	}
}
