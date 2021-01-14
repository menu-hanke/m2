local function readjson(fname)
	local decode = require "json.decode"
	local fp = io.open(fname)
	if not fp then return nil end
	local ret = decode(fp:read("*a"))
	fp:close()
	return ret
end

local function delegate(owner, f)
	return function(...)
		return f(owner, ...)
	end
end

local function merge(dest, src)
	for k,v in pairs(src) do
		dest[k] = v
	end
	return dest
end

local function dofile_env(env, fname)
	if not fname then
		error("Missing file name to read()", 2)
	end

	local f, err = loadfile(fname, nil, env)

	if not f then
		error(string.format("Failed to read file: %s", err), 2)
	end

	f()
end

return {
	readjson   = readjson,
	delegate   = delegate,
	merge      = merge,
	dofile_env = dofile_env,
}
