require "m2_cdef"
require "glob_util"

local function parse_args(args)
	local idx = 2
	local ret = {}

	while idx <= #args do
		if args[idx] == "-F" then
			ret.mode = "fill"
		elseif args[idx] == "-S" then
			ret.simulate = true
		elseif args[idx] == "-c" then
			idx = idx+1
			ret.config = args[idx]
		elseif args[idx] == "-i" then
			idx = idx+1
			ret.input = args[idx]
		elseif args[idx] == "-f" then
			idx = idx+1
			local obj,fields = args[idx]:match("^([^:]+):(.+)$")
			fields = map(split(fields), trim)
			ret.fill = { obj=obj, fields=fields }
		elseif args[idx] == "-o" then
			idx = idx+1
			ret.output = args[idx]
		else
			io.stderr:write("Ignored unknown argument '" .. args[idx] .. "'\n")
		end

		idx = idx+1
	end

	return ret
end

function main(args)
	local args = parse_args(args)

	--if args.mode == "fill" then
	if args.fill then
		(require "fill").main(args)
	elseif args.simulate then
		(require "simulate").main(args)
	end

	collectgarbage() --debug

	return 0
end
