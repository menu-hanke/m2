require "m2_cdef"
require "glob_util"

local function opt(name)
	return function(ret, n)
		ret[name] = n()
	end
end

local function flag(name)
	return function(ret)
		ret[name] = true
	end
end

local argdef = {

	simulate = {
		c = opt("config")
	},

	fhkdbg= {
		c = opt("config"),
		i = opt("input"),
		f = function(ret, n) ret.vars = map(split(n()), trim) end
	}

}

-------------------------

local function parse_args(args)
	-- skip first arg (program name)
	local idx = 1
	local iter = function()
		idx = idx + 1
		return args[idx]
	end

	local cmd
	if #args<2 or args[2]:sub(1, 1) == "-" then
		cmd = "simulate"
	else
		cmd = args[2]
		iter()
	end

	local ad = argdef[cmd]

	if not ad then
		error(string.format("Unknown command '%s'", cmd))
	end

	local ret = {}

	while true do
		local flag = iter()
		if not flag then
			break
		end

		if flag:sub(1, 1) ~= "-" then
			error(string.format("Invalid argument: '%s'", flag))
		end

		local cb = ad[flag:sub(2)]
		if not cb then
			error(string.format("Unknown flag: '%s'", flag))
		end

		cb(ret, iter)
	end

	return cmd, ret
end

-------------------------

function main(args)
	local cmd, args = parse_args(args)
	require(cmd).main(args)
	collectgarbage() --debug
	return 0
end
