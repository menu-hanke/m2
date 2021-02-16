local function copytable(x)
	local ret = {}
	for name, value in pairs(x) do
		ret[name] = value
	end
	return ret
end

local function append(a, b)
	for _,x in ipairs(b) do
		table.insert(a, x)
	end
	return a
end

local function bootstrap(path)
	local old_path = package.path
	local old_loaded = copytable(package.loaded)

	package.path = path .. ";" .. package.path

	-- now require is available

	require "m2_cdef"
	require "alloc"   -- required here because this introduces the cdef for malloc and free
	require("scripting").init_sandbox(require("sandbox").capture({
		path = old_path,
		loaded = old_loaded
	}))
end

local function jit_cmd(stream)
	-- -j<module>=<args>
	local module, args = stream.token:match("-j(%w+)=?(.*)")
	if not module then
		return
	end

	stream()

	local argv = {}
	for s in args:gmatch("[^,]+") do
		table.insert(argv, s)
	end

	require("jit."..module).start(unpack(argv))
end

local function main(args)
	local misc = require "misc"
	local cli = require "cli"

	local cmd_name, cmd
	local flags = cli.combine {
		cli.flag("-v", "verbose"),
		cli.flag("-q", "quiet"),
		cli.flag("-h", "help"),
		jit_cmd,

		function(stream, result) -- subcommand, this must be last
			if not cmd then
				cmd_name = stream()
				cmd = require(cmd_name).cli
				if not cmd then
					error(string.format("Module '%s' loaded but it doesn't export `cli`", cmd_name))
				end
				return
			end

			if cmd.flags then
				return cmd.flags(stream, result)
			end
		end
	}

	local args = cli.parse(flags, args, 2)

	if cmd and args.help then
		print(string.format("usage: m2 %s %s", cmd_name, cmd.help))
		return 0
	end

	if (not cmd) or args.help then
		print("usage: m2 <subcommand> [options]...")
		print("\nglobal options:")
		print("  -v/-q   verbose/quiet")
		print("  -jcmd   pass <cmd> to luajit")
		return 0
	end

	cli.install_logger((args.quiet or 0) - (args.verbose or 0))
	cmd.main(args)

	return 0
end

return {
	bootstrap = bootstrap,
	main      = main
}
