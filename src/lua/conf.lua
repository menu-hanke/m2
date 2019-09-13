local typing = require "typing"

local function create_enums(data)
	local ret = {}

	for name,t in pairs(data.types) do
		if t.kind == "enum" then
			local e = typing.newenum()
			for k,i in pairs(t.def) do
				e.values[k] = i
			end
			ret[name] = e
		end
	end

	return ret
end

local function create_type(data, enums, types, t)
	if types[t.name] then
		return types[t.name]
	end

	if t._parsing then
		error(string.format("Recursive type definition: '%s' references itself", t.name))
	end

	t._parsing = true

	local tp = typing.newtype(t.name)
	for name,vt in pairs(t.def) do
		if data.types[vt] and data.types[vt].kind == "struct" then
			create_type(data, enums, types, data.types[vt])
		end
		local desc = typing.builtin_types[vt] or types[vt] or enums[vt] or vt
		if not desc.ctype then
			error(string.format("Type not resolved: %s (in var '%s' of type '%s')",
				tostring(vt), name, t.name))
		end
		tp.vars[name] = desc
	end

	t._parsing = nil
	types[t.name] = tp
end

local function create_types(data, enums)
	local types = {}

	for name,t in pairs(data.types) do
		if t.kind == "struct" then
			create_type(data, enums, types, t)
		end
	end

	return types
end

local function export_fhk_vars(data, types, enums)
	local ret = {}

	for name,vtype in pairs(data.vars) do
		ret[name] = typing.builtin_types[vtype] or enums[vtype]

		if not ret[name] then
			error(string.format("Not an exportable type '%s' (of fhk var '%s')",
				vtype, name))
		end
	end

	for tname,_ in pairs(data.type_exports) do
		if not types[tname] then
			error(string.format("Can't export type '%s': no definition found", tname))
		end

		for name,vtype in pairs(types[tname].vars) do
			if ret[name] and vtype ~= ret[name] then
				error(string.format("Trying to export var '%s' as conflicting types ('%s' and '%s')",
					name, vtype.ctype, ret[name].ctype))
			end
			if vtype.desc then
				ret[name] = vtype
			end
		end
	end

	return ret
end

local function create_check(cst, vtypes, vname, mname)
	local vt = vtypes[vname]
	if not vt then
		error(string.format("Undefined var '%s' (in constraints of model '%s')", vname, mname))
	end

	if cst.type == "any" or cst.type == "none" then
		local mask = 0ULL
		for _,v in ipairs(cst.values) do
			if type(v) == "string" then
				if vt.kind ~= "enum" then
					error(string.format("Enum member '%s' given as constraint for '%s' but its"
						.." type is '%s' (%s), not enum", v, vname, vt.kind, vt.ctype))
				end

				if not vt.values[v] then
					error(string.format("Not a valid enum member '%s' (constraint '%s' of model '%s')",
						v, vname, mname))
				end

				v = vt.values[v]
			end

			mask = bit.bor(mask, v)
		end

		if cst.type == "none" then
			mask = bit.bnot(mask)
		end

		cst.type = "set"
		cst.values = nil
		cst.mask = mask
	end

	return cst
end

local function create_models(data, vtypes)
	for name,model in pairs(data.models) do
		for vname,cst in pairs(model.checks) do
			model.checks[vname] = create_check(cst, vtypes, vname, model.name)
		end
	end

	return data.models
end

local function newconf()
	local conf_env = get_builtin_file("conf_env.lua")
	local env, data = dofile(conf_env)
	return env, data
end

local function read(...)
	local env, data = newconf()

	local fnames = {...}
	for _,f in ipairs(fnames) do
		env.read(f)
	end

	local enums = create_enums(data)
	local types = create_types(data, enums)
	local fhk_vars = export_fhk_vars(data, types, enums)
	local fhk_models = create_models(data, fhk_vars)

	return {
		enums = enums,
		types = types,
		calib = data.calib,
		fhk_vars = fhk_vars,
		fhk_models = fhk_models
	}
end

return {
	read = read
}
