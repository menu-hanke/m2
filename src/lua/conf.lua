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

local function resolve_lazy(data, vars, t)
	for name,_ in pairs(t.lazy) do
		-- explicitly defined types take priority
		if not t.def[name] then
			local v = vars[name]
			if not v then
				error(string.format("No variable corresponding to struct member: %s.%s",
					t.name, name))
			end
			t.def[name] = v.type
		end
	end
end

local function typecheck_def(vars, t)
	for name,type in pairs(t.def) do
		if vars[name] and vars[name].type ~= type then
			error(string.format("Struct '%s' and fhk disagree about type of '%s' (%s vs. %s)",
				t.name, name, type.ctype, vars[name].type.ctype))
		end
	end
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

local function create_types(data, enums, vars)
	local types = {}

	for name,t in pairs(data.types) do
		if t.kind == "struct" then
			resolve_lazy(data, vars, t)
			typecheck_def(vars, t)
			create_type(data, enums, types, t)
		end
	end

	return types
end

local function export_fhk_vars(data, enums)
	for name,def in pairs(data.vars) do
		local dtype = typing.builtin_types[def.type] or enums[def.type]

		if not dtype then
			error(string.format("Not an exportable type '%s' (of fhk var '%s')", def.type, name))
		end

		def.type = dtype
	end

	return data.vars
end

local function create_check(cst, vars, vname, mname)
	if not vars[vname] then
		error(string.format("Undefined var '%s' (in constraints of model '%s')", vname, mname))
	end

	local vt = vars[vname].type

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

local function create_models(data, vars)
	for name,model in pairs(data.models) do
		for vname,cst in pairs(model.checks) do
			model.checks[vname] = create_check(cst, vars, vname, model.name)
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
	local fhk_vars = export_fhk_vars(data, enums)
	local types = create_types(data, enums, fhk_vars)
	local fhk_models = create_models(data, fhk_vars)

	return {
		enums = enums,
		types = types,
		calib = data.calib,
		modules = data.modules,
		fhk_vars = fhk_vars,
		fhk_models = fhk_models
	}
end

local function read_cmdline(fname)
	return read(fname or "Melasim.lua")
end

return {
	read         = read,
	read_cmdline = read_cmdline
}
