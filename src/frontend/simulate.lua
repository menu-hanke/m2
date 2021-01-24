local misc = require "misc"
local cli = require "cli"
local sim_env = require "sim_env"

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
				cli.verbose("[%s] %d/%d", args.input, i, #data)
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

local flags, help = cli.def(function(opt)
	opt { "<instructions>", help="instruction file" }
	opt { "-F", "nframes", help=string.format("allocate {nframes} frames (default: %d)", DEFAULT_FRAMES) }
	opt { "-R", "rsize", help=string.format("allocate 2^{rsize}-sized regions (default: 2^%d)", DEFAULT_RSIZE) }
	opt { "-i", "input", help="input file" }
	opt { "-c", "config", help="config file" }
	opt { "-s", "script", help="additional scripts", multiple=true }
end)

return {
	cli = {
		main = main,
		help = "[instructions] [options]...\n\n"..help,
		flags = flags
	}
}
