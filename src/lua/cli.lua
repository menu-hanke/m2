local function yieldarg(peek, val, typ)
	if type(peek) == "string" then
		if peek == typ then
			-- yield & consume wanted type
			return coroutine.yield(val, typ)
		else
			-- yield nil and peek for unwanted type
			return yieldarg(coroutine.yield(), val, typ)
		end
	end

	local peeknext = coroutine.yield(val, typ)
	return peek and yeildarg(peeknext, val, typ) or peeknext
end

local function parser(args)
	return coroutine.wrap(function(peek)
		for _, arg in ipairs(args) do
			if arg:sub(1, 1) == "-" then
				-- allow specifying value here, like:
				--   -jdump
				-- or:
				--   -j dump
				local flag, val = arg:match("-(%a)(.*)")
				peek = yieldarg(peek, flag, "flag")
				if #val > 0 then
					peek = yieldarg(peek, val, "val")
				end
			else
				peek = yieldarg(peek, arg, "val")
			end
		end

		-- allow peeking end
		while peek do
			peek = coroutine.yield()
		end
	end)
end

local function parse_opts(P, opts)
	local ret = {}

	while true do
		local val, typ = P()

		if not typ then
			return ret
		end

		if typ ~= "flag" then
			error(string.format("Invalid argument: '%s'", val))
		end

		local opt = opts[val]
		if not opt then
			error(string.format("Unknown flag: -%s", val))
		end

		opt(ret, P)
	end
end

--------------------------------------------------------------------------------

local function opt(name)
	return function(ret, P)
		ret[name] = P()
	end
end

local function addopt(name)
	return function(ret, P)
		ret[name] = ret[name] or {}
		local v = P()
		table.insert(ret[name], v)
	end
end

local function setopt(name)
	return function(ret, P)
		ret[name] = ret[name] or {}
		ret[name][P()] = true
	end
end

local function flag(name)
	return function(ret)
		ret[name] = true
	end
end

return {
	parser     = parser,
	parse_opts = parse_opts,

	opt        = opt,
	addopt     = addopt,
	setopt     = setopt,
	flag       = flag
}
