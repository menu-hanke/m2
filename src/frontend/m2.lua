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
	require("sim_env").init_sandbox(old_path, old_loaded)
end

local function help()
end

local function main(args)
	local misc = require "misc"
	local cli = require "cli"

	local flags = {
		cli.flag("-v", "verbose"),
		cli.flag("-q", "quiet"),
		cli.flag("-h", "help"),
		function(a) -- -j<module>=<args>
			local module, args = a:match("-j(%w+)=?(.*)")
			if module then
				require("jit."..module).start(unpack(misc.split(args or "")))
				return true
			end
		end
	}

	local cmd = args[2]
	local ok, sub = pcall(function() return require(cmd).cli_main end)
	if not ok then
		print("Usage: m2 <subcommand> [options]...")
		print("Global options:")
		print("  -v/-q   Verbose/quiet")
		print("  -jcmd   Pass <cmd> to luajit")

		if cmd then
			print("\nIf you meant to run a subcommand, this is the load error:")
			print(sub)
		end

		return 1
	end

	local opt = cli.parse(append(flags, sub.flags or {}), args, 3)
	if opt.help then
		print(string.format("Usage: m2 %s %s", cmd, sub.usage))
		return 1
	end

	require("log").logger:setlevel((opt.quiet or 0) - (opt.verbose or 0))
	sub.main(opt)
	return 0
end

return {
	bootstrap = bootstrap,
	main      = main
}
