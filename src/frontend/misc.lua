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

local function _capture_ivar(state, idx, ivar, ...)
	if ivar == nil then
		return
	end

	state.ivar = ivar
	return idx, ivar, ...
end

local function _enumerate_next(state, idx)
	return _capture_ivar(state, idx+1, state.inext(state.is, state.ivar))
end

-- return a wrapped iterator that appends an index as the first value
local function enumerate(inext, is, ivar)
	local state = { inext=inext, is=is, ivar=ivar }
	return _enumerate_next, state, -1
end

local function _ipairs0_next(tab, idx)
	if tab[idx+2] ~= nil then
		return idx+1, tab[idx+2]
	end
end

-- same as ipairs but 0-based, useful for C glue code.
-- note that using ipairs and manually offsetting the index is faster
-- (but using a for loop with explicit indexing is even faster, so use that for perf
-- sensitive code)
local function ipairs0(tab)
	return _ipairs0_next, tab, -1
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
	enumerate  = enumerate,
	ipairs0    = ipairs0,
	dofile_env = dofile_env,
}
