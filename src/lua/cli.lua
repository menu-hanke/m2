local function parse(parsers, args, idx)
	local ret = {}

	idx = idx-1 -- first argument is the next one
	local function arg(peek, offset)
		-- TODO: if we want to handle flags like gnu tools, just interpret -abc as -a -b -c
		offset = offset or 1
		local ret = args[idx + offset]
		if not peek then idx = idx + offset end
		return ret
	end

	while true do
		local a = arg()
		if not a then break end
		for _,p in ipairs(parsers) do
			if p(a, ret, arg) then goto continue end
		end
		error(string.format("Failed to parse command line arguments here -> '%s'", a))
		::continue::
	end

	return ret
end

local function opt(flag, name, mode)
	return function(a, ret, arg)
		if a == flag then
			local value = arg() or error("Unexpected end of command line arguments")

			if mode == "multiple" then
				ret[name] = ret[name] or {}
				table.insert(ret[name], value)
			elseif mode == "map" then
				ret[name] = ret[name] or {}
				ret[name][value] = true
			else
				ret[name] = value
			end

			return true
		end
	end
end

local function flag(flag, name)
	return function(a, ret)
		-- handle also repetitions, like "-vvv"
		if a == flag or (a == flag .. flag:sub(2):rep(#a-2)) then
			ret[name] = (ret[name] or 0) + a:len()-1
			return true
		end
	end
end

local function positional(name)
	return function(a, ret)
		if a:sub(1, 1) ~= "-" and not ret[name] then
			ret[name] = a
			return true
		end
	end
end

return {
	parse      = parse,
	opt        = opt,
	flag       = flag,
	positional = positional
}
