require "m2_cdef"
require "alloc"
local aux = require "aux"
local cli = require "cli"

function main(args)
	local P = cli.parser(args)
	P() -- skip file name

	local cmd = P("val") or "simulate"
	cmd = require(cmd)
	local flags = cmd.flags or {}

	flags.j = function(_, P)
		local val = P()
		local module, args = val:match("(%w+)=?(.*)")
		require("jit."..module).start(unpack(aux.split(args or "")))
	end

	cmd.main(cli.parse_opts(P, flags))
	return 0
end
