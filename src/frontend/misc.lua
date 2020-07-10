local function split(str)
	local ret = {}

	for s in str:gmatch("[^,]+") do
		table.insert(ret, s)
	end

	return ret
end

local function map(tab, f)
	local ret = {}

	for k,v in pairs(tab) do
		ret[k] = f(v)
	end

	return ret
end

local function trim(str)
	-- ignore second return val
	str = str:gsub("^%s*(.*)%s*$", "%1")
	return str
end

local function readcsv(fname)
	local f = io.open(fname)
	local header = map(split(f:read()), trim)
	local data = {}

	for l in f:lines() do
		local d = map(split(l), trim)
		if #d ~= #header then
			error(string.format("Invalid line: %s (expected %d values but have %d)",
				l, #d, #header))
		end
		table.insert(data, d)
	end

	f:close()

	return header, data
end

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

local function keys(x)
	local ret = {}
	for k,_ in pairs(x) do
		table.insert(ret, k)
	end
	return ret
end

local function countkeys(t)
	local nk = 0
	for _,_ in pairs(t) do
		nk = nk + 1
	end
	return nk
end

local function lazy(fs, index)
	index = index or {}
	return function(self, k)
		if fs[k] then
			local v = fs[k](self)
			self[k] = v
			return v
		end

		return index[k]
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

local function skip(n, _f, _s, _var)
	for i=1, n do
		local _v = _f(_s, _var)
		if _v == nil then break end
		_var = _v
	end

	return _f, _s, _var
end

-- TODO siivoa
return {
	split      = split,
	map        = map,
	trim       = trim,
	readjson   = readjson,
	readcsv    = readcsv,
	delegate   = delegate,
	keys       = keys,
	countkeys  = countkeys,
	lazy       = lazy,
	merge      = merge,
	dofile_env = dofile_env,
	skip       = skip
}
