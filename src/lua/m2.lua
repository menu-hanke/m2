require "m2_cdef"
require "arena"
require "malloc"
require "glob_util"
local cli = require "cli"

function main(args)
	local ai, cmd
	if #args<2 or args[2]:sub(1, 1) == "-" then
		cmd = require "simulate"
		ai = cli.argiter(args, 2)
	else
		cmd = require(args[2])
		ai = cli.argiter(args, 3)
	end

	local flags = cmd.flags

	flags.j = function(_, _, flag)
		local module, args = flag:match("-j(%w+)=?(.*)", 3)
		require("jit."..module).start(unpack(split(args or "")))
	end

	cmd.main(cli.parse(ai, flags))
	return 0
end
