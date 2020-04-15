-- functions for setting up lua envs

local function read(env, fname)
	if not fname then
		error("Missing file name to read()", 2)
	end

	local f, err = loadfile(fname, nil, env)

	if not f then
		error(string.format("Failed to read file: %s", err), 2)
	end

	f()
end

-- TODO?: require hook here instead of sim_env ?

local function namespace(index)
	return setmetatable({}, {
		__index=function(_, k)
			return function(...)
				index(k, ...)
			end
		end,
		__newindex=function(_, k, ...)
			index(k, ...)
		end
	})
end

return {
	read      = read,
	namespace = namespace
}
