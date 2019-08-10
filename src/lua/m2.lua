require "m2_cdef"
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

local m2args = {
	jv = flag("jit_v"),
	jp = flag("jit_p"),
	jP = opt("jit_p")
}

local subargs = {

	simulate = {
		c = opt("config"),
		s = addopt("scripts")
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

	local ad = subargs[cmd]

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

		local cb = ad[flag:sub(2)] or m2args[flag:sub(2)]
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

	if args.jit_v then
		(require "jit.v").on()
	end

	if args.jit_p then
		local opt = type(args.jit_p) ~= "boolean" and args.jit_p or nil
		(require "jit.p").start(opt)
	end

	require(cmd).main(args)

	collectgarbage() --debug

	if args.jit_p then
		(require "jit.p").stop()
	end

	return 0
end
