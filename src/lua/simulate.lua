local conf = require "conf"
local sim_env = require "sim_env"

local function main(args)
	if not args.scripts then error("No scripts given, give some with -s") end
	if not args.instr then error("No instructions, give some with -I") end

	local cfg = conf.read(args.config)
	local env = sim_env.from_conf(cfg)

	for _,s in ipairs(args.scripts) do
		env:run_file(s)
	end

	local instr = env:run_file(args.instr)

	if args.input then
		local data = readjson(args.input)
		local sim = env.sim
		sim:savepoint()
		for i,v in ipairs(data) do
			io.stderr:write(string.format("[%s] %d/%d\n", args.input, i, #data))
			sim:enter()
			env:setup(v)
			env:simulate(instr)
			sim:exit()
			sim:restore()
		end
	else
		env:simulate(instr)
	end
end

return { main=main }
