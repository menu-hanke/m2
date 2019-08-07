local ffi = require "ffi"
local json = require "json"

local function gsize(resolution)
	return ffi.C.grid_max(2*resolution)
end

local function parse_envdata(d, env)
	if #d ~= gsize(env.resolution) then
		error(string.format("%s: expected %d entries but got %d", env.name,
			gsize(env.resolution), #d))
	end

	return d
end

local function parse_objdata(d, obj)
	local ret = {}

	if #d == 0 then
		return ret
	end

	for k,_ in pairs(d[1]) do
		ret[k] = {}
	end

	for i,v in ipairs(d) do
		for k,_ in pairs(obj) do
			if not ret[k] then
				error(string.format("Extra var '%s' in obj %d", k, i))
			end
		end

		for k,l in pairs(ret) do
			if not v[k] then
				error(string.format("Var '%s' missing in obj %d", k, i))
			end

			l[i] = v[k]
		end
	end

	return ret
end

local function parse(d, cdata)
	local envs = {}
	local objs = {}

	for k,v in pairs(d) do
		if cdata.envs[k] then
			envs[k] = parse_envdata(v, cdata.envs[k])
		elseif cdata.objs[k] then
			objs[k] = parse_objdata(v, cdata.objs[k])
		else
			error(string.format("Name '%s' is not env or obj", k))
		end
	end

	return envs, objs
end

local function read_json(fname, cdata)
	local fp = io.open(fname)
	local data = json.decode(fp:read("*a"))
	io.close(fp)
	return parse(ret, cdata)
end

return {
	read_json=read_json
}
