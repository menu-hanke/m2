local typing = require "typing"

local function create_classifications(data)
	for name,t in pairs(data.class) do
		data.class[name] = typing.class(data.class[name])
	end
end

local function resolve_fhk_var_types(data)
	for name,def in pairs(data.vars) do
		def.ptype = typing.pvalues[def.type] or
			error(string.format("Invalid pvalue type: '%s' (of fhk var '%s')", def.type, name))
		def.class = data.class[def.class]
	end
end

local function resolve_constraint(model, var, cst)
	if cst.type == "any" or cst.type == "none" then
		local mask = 0ULL

		for _,v in ipairs(cst.values) do
			if type(v) == "string" then
				local class = var.class or
					error(string.format("No class defined for target variable '%s' (constraint of model '%s')",
						var.name, model.name))
				v = class[v] or
					error(string.format("No such class member: '%s' (constraint '%s' of model '%s')",
						v, var.name, model.name))
			else
				v = 2ULL^v
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

	-- Nothing needs to be done for interval constraints
end

local function resolve_fhk_constraints(data)
	for name,model in pairs(data.models) do
		for vname,cst in pairs(model.checks) do
			resolve_constraint(
				model,
				data.vars[vname] or
					error(string.format("Undefined var '%s' (in constraint of model '%s')",
						vname, name)),
				cst
			)
		end
	end
end

local function get_builtin_file(fname)
	-- XXX: this is a turbo hack, it relies on the C code putting this as the first thing
	-- in search path, this should be written in C and replace on M2_LUAPATH
	return package.path:gsub("%?.lua;.*$", fname)
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

	create_classifications(data)
	resolve_fhk_var_types(data)
	resolve_fhk_constraints(data)

	return {
		class      = data.class,
		calib      = data.calib,
		modules    = data.modules,
		fhk_vars   = data.vars,
		fhk_models = data.models
	}
end

local function read_cmdline(fname)
	return read(fname or "Melasim.lua")
end

return {
	read         = read,
	read_cmdline = read_cmdline
}
