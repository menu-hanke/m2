local function argiter(args, start)
	local idx = (start or 1) - 1
	return function()
		idx = idx+1
		return args[idx]
	end
end

local function opt(name)
	return function(ret, ai)
		ret[name] = ai()
	end
end

local function addopt(name)
	return function(ret, ai)
		ret[name] = ret[name] or {}
		table.insert(ret[name], ai())
	end
end

local function setopt(name)
	return function(ret, ai)
		ret[name] = ret[name] or {}
		ret[name][ai()] = true
	end
end

local function flag(name)
	return function(ret)
		ret[name] = true
	end
end

local function parse(ai, opts)
	local ret = {}

	while true do
		local flag = ai()
		if not flag then return ret end

		if flag:sub(1, 1) ~= "-" then
			error(string.format("Invalid argument: '%s'", flag))
		end

		local o = opts[flag:sub(2, 2)]
		if not o then
			error(string.format("Unknown option: -%s", flag:sub(2, 2)))
		end

		o(ret, ai, flag)
	end
end

return {
	argiter = argiter,
	parse   = parse,
	opt     = opt,
	addopt  = addopt,
	setopt  = setopt,
	flag    = flag
}
