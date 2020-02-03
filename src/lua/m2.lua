local function copytable(x)
	local ret = {}
	for name, value in pairs(x) do
		ret[name] = value
	end
	return ret
end

local function bootstrap(path)
	local old_path = package.path
	local old_loaded = copytable(package.loaded)

	package.path = path .. ";" .. package.path

	-- now require is available

	require "m2_cdef"
	require "alloc"   -- required here because this introduces the cdef for malloc and free
	require("sim_env").init_sandbox(old_path, old_loaded)
end

local function main(args)
	local aux = require "aux"
	local cli = require "cli"

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

return {
	bootstrap = bootstrap,
	main      = main
}
