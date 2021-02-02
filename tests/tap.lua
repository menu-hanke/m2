local function fails(f, err)
	if type(f) == "string" then
		return function(g) return fails(g, f) end
	end

	local ok, mes = pcall(f)
	if ok then return false end
	return (not err) or mes:match(err)
end

local env_mt = {
	__newindex = function(self, k, v)
		if self._only and not self._only[k] then
			return
		end
		if type(k) == "string" and k:sub(1, 5) == "test_" then
			table.insert(self._tests, {name=k, func=v})
		end
	end,

	__index = setmetatable({
		fails = fails
	}, {__index=_G})
}

local function env()
	return setmetatable({_tests={}}, env_mt)
end

local function runtests(tests, out)
	out:write("1..", #tests, "\n")
	for i,t in ipairs(tests) do
		local ok, err = xpcall(t.func, debug.traceback)
		if ok then
			out:write("ok ", i, " - ", t.name, "\n")
		else
			out:write("not ok ", i, " - ", t.name, "\n")
			out:write("# ", err:gsub("\n", "\n# "), "\n")
		end
	end
end

local function collect(env, fname)
	local f, err = loadfile(fname, nil, env)
	if err then
		io.stderr:write(err, "\n")
		os.exit(1)
	end
	f()
end

local function main(args)
	local env = env()
	rawset(env, "_only", args.run)

	for i,f in ipairs(args.tests) do
		collect(env, f)
	end

	runtests(env._tests, io.stdout)
end

--------------------------------------------------------------------------------

if arg then
	-- we are being run standalone as:
	-- luajit tap.lua $m2 $test
	env_mt.__index.m2_cmd = arg[1]
	main({tests={arg[2]}})
else
	-- we are inside m2:
	-- $m2 tap -t $test
	local cli = require "cli"

	local flags, help = cli.def(function(opt)
		opt { "-t", "tests", help="test files", multiple=true }
		opt { "-r", "run", help="tests to run", set=true }
	end)

	return {
		cli = {
			main = main,
			help = "[options]\n\n"..help,
			flags = flags
		}
	}
end
