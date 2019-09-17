require "m2_cdef"
require "arena"
require "glob_util"

local function opt(name)
	return function(ret, n)
		ret[name] = n()
	end
end

local function addopt(name)
	return function(ret, n)
		ret[name] = ret[name] or {}
		table.insert(ret[name], n())
	end
end

local function flag(name)
	return function(ret)
		ret[name] = true
	end
end

local cmdargs = {

	simulate = {
		c = opt("config"),
		s = addopt("scripts"),
		i = opt("input"),
		I = opt("instr")
	},

	fhkdbg = {
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

	local ad = cmdargs[cmd]

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
		if cb then
			cb(ret, iter)
		elseif flag:sub(2, 2) == "j" then
			local module, args = flag:match("(%w+)=?([%w,]*)", 3)
			require("jit."..module).start(args and unpack(split(args)))
		else
			error(string.format("Unknown flag: '%s'", flag))
		end
	end

	return cmd, ret
end

-------------------------

function main(args)
	local cmd, args = parse_args(args)
	require(cmd).main(args)
	return 0
end
