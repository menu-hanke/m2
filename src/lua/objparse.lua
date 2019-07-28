local json = require "json"

local function toposort_refs(ret, obj)
	if ret[obj] then
		return
	end

	for _,o in ipairs(obj.uprefs) do
		toposort_refs(ret, o)
	end

	table.insert(ret, obj)
	ret[obj] = true
end

local function toposort_objs(objs)
	local ret = {}
	for _,v in pairs(objs) do
		toposort_refs(ret, v)
	end
	return ret
end

local function create_vecs(S, confdata, init)
	local objs = toposort_objs(confdata.objs)
	local refs = {}

	for _,o in ipairs(objs) do
		if init[o.name] then
			refs[o.name] = {}

			for k,v in pairs(init[o.name]) do
				local uprefs = {}
				if #o.uprefs>0 then
					for i,u in ipairs(o.uprefs) do
						uprefs[i] = refs[u.name][v.uprefs[u.name]]
					end
				end

				local ref = S:alloc1(o.name, unpack(uprefs))
				refs[o.name][k] = ref

				for name,val in pairs(v.vars) do
					ref[name] = val
				end
			end
		end
	end
end

local function read_json(fname)
	local fp = io.open(fname)
	local ret = json.decode(fp:read("*a"))
	io.close(fp)
	return ret
end

local function read_vecs(S, confdata, fname)
	local init = read_json(fname)
	create_vecs(S, confdata, init)
end

return {
	read_vecs=read_vecs
}
