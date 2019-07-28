local ffi = require "ffi"
local C = ffi.C

local builtin_types = {
	f32 = C.T_F32,
	f64 = C.T_F64,
	i8  = C.T_I8,
	i16 = C.T_I16,
	i32 = C.T_I32,
	i64 = C.T_I64,
	b8  = C.T_B8,
	b16 = C.T_B16,
	b32 = C.T_B32,
	b64 = C.T_B64
}

local function newconf()
	-- XXX: this is a turbo hack, it relies on the C code putting this as the first thing
	-- in search path
	local conf_env = package.path:gsub("%?.lua;.*$", "conf_env.lua")
	local env, data = dofile(conf_env)
	return env, data
end

local function resolve_types(data)
	for _,v in pairs(data.vars) do
		local dtype = v.type
		if not builtin_types[dtype] then
			error(string.format("No definition found for type '%s' of variable '%s'",
				dtype, v.name))
		end

		v.type = builtin_types[dtype]
		
		-- TODO: non-builtins
	end
end

local function link_graph(data)
	for _,v in pairs(data.vars) do
		v.models = {}
	end

	for _,m in pairs(data.fhk_models) do
		for i,p in ipairs(m.params) do
			local v = data.vars[p]
			if not v then
				error(string.format("No var definition found for parameter '%s' of model '%s'",
					p, m.name))
			end

			m.params[i] = v
			-- delete named version, only used for dupe checking in conf_env
			m.params[p] = nil
		end

		for i,c in ipairs(m.checks) do
			local v = data.vars[c.var]
			if not v then
				error(string.format("No var definition '%s' found for check #%d of model '%s'",
					c.var, i, m.name))
			end

			c.var = v
		end

		local v = data.vars[m.returns]
		if not v then
			error(string.format("No var definition '%s' for return value of model '%s'",
				m.returns, m.name))
		end

		m.returns = v
		table.insert(v.models, m)
	end
end

local function link_objects(data)
	for _,o in pairs(data.objs) do
		for i,f in ipairs(o.fields) do
			local v = data.vars[f]
			if not v then
				error(string.format("No var definition found for field '%s' of obj '%s'",
					f, o.name))
			end

			o.fields[i] = v
		end

		for i,u in ipairs(o.uprefs) do
			local up = data.objs[u]
			if not up then
				error(string.format("No obj definition found for upref '%s' of obj '%s'",
					u, o.name))
			end

			o.uprefs[i] = up
		end
	end
end

local function verify_models(data)
	for _,m in pairs(data.fhk_models) do
		if not m.impl then
			error(string.format("Missing impl for model '%s'", m.name))
		end
	end
end

local function read(...)
	local env, data = newconf()

	local fnames = {...}
	for _,f in ipairs(fnames) do
		env.read(f)
	end

	resolve_types(data)
	link_graph(data)
	link_objects(data)
	verify_models(data)

	return data
end

local function get_lexicon(data)
	local types = {} -- TODO
	local vars = {}
	local objs = collect(data.objs)

	-- only take actually referenced vars, the others are fhk computed vars/etc.
	for _,o in ipairs(objs) do
		for _,f in ipairs(o.fields) do
			vars[f.name] = f
		end
	end

	vars = collect(vars)

	local arena = C.arena_create(1024)
	local lex = ffi.gc(C.lex_create(#types, #vars, #objs), function(lex)
		C.lex_destroy(lex)
		C.arena_destroy(arena)
	end)

	for i,v in ipairs(vars) do
		v._lexid = i-1
		v._ptr = lex.vars.data + v._lexid
		v._ptr.name = arena_copystring(arena, v.name)
		v._ptr.type = v.type
	end

	for i,o in ipairs(objs) do
		o._lexid = i-1
		o._ptr = lex.objs.data + o._lexid
		o._ptr.name = arena_copystring(arena, o.name)
	end

	for i,o in ipairs(objs) do
		if #o.fields>0 then
			local fs = ffi.new("lexid[?]", #o.fields)
			for j,f in ipairs(o.fields) do
				fs[j-1] = f._lexid
			end
			C.lex_set_vars(lex, o._lexid, #o.fields, fs)
		end

		if #o.uprefs>0 then
			local us = ffi.new("lexid[?]", #o.uprefs)
			for j,u in ipairs(o.uprefs) do
				us[j-1] = u._lexid
			end
			C.lex_set_uprefs(lex, o._lexid, #o.uprefs, us)
		end
	end

	C.lex_compute_refs(lex)

	return {
		lex=lex,
		objs=objs,
		vars=vars
	}
end

local function copy_ival_cst(check, vdef, a, b)
	local ptype = C.tpromote(vdef.type)

	if ptype == C.PT_REAL then
		check.cst.type = C.FHK_RIVAL
		check.cst.rival.min = a
		check.cst.rival.max = b
	elseif ptype == C.PT_INT then
		check.cst.type = C.FHK_IIVAL
		check.cst.iival.min = a
		check.cst.iival.max = b
	else
		error(string.format("invalid ptype for interval constraint: %d", tonumber(ptype)))
	end
end

local function copy_set_cst(check, values)
	local mask = 0

	for _,v in ipairs(values) do
		if v<0 or v>63 then
			error(string.format("invalid bitset value: %d", v))
		end

		-- XXX: not sure if lua actually has 64-bit integers,
		-- maybe this should be done in C
		mask = bit.bor(mask, tonumber(C.packenum(v)))
	end

	check.cst.type = C.FHK_BITSET
	check.cst.setmask = mask
end

local function copy_cst(check, vdef, cst)
	if cst.type == "ival" then
		copy_ival_cst(check, vdef, cst.a, cst.b)
	elseif cst.type == "set" then
		copy_set_cst(check, cst.values)
	else
		error(string.format("invalid cst type '%s'", cst.type))
	end
end

local function create_checks(model, checks, arena)
	model.n_check = #checks

	if #checks == 0 then
		return
	end

	model.checks = C.arena_malloc(arena, ffi.sizeof("struct fhk_check[?]", model.n_check))

	for i=0, #checks-1 do
		local c = model.checks+i
		local check = checks[i+1]
		c.var = check.var._ptr
		c.costs[C.FHK_COST_IN] = check.cost_in
		c.costs[C.FHK_COST_OUT] = check.cost_out
		copy_cst(c, check.var, check.cst)
	end
end

local function get_fhk_graph(data)
	local models = collect(data.fhk_models)
	local vars = {}

	-- same as lex, only take vars that appear
	for _,m in pairs(data.fhk_models) do
		for _,p in ipairs(m.params) do
			vars[p] = p
		end
		for _,c in ipairs(m.checks) do
			vars[c.var] = c.var
		end
		vars[m.returns] = m.returns
	end

	vars = collect(vars)

	local arena = C.arena_create(4096)

	local n_models = #models
	local n_vars = #vars

	local c_models = ffi.cast("struct fhk_model *", C.arena_malloc(arena,
		ffi.sizeof("struct fhk_model[?]", n_models)))
	local c_vars = ffi.cast("struct fhk_var *", C.arena_malloc(arena,
		ffi.sizeof("struct fhk_var[?]", n_vars)))

	for i=0, n_models-1 do
		models[i+1]._ptr = c_models+i
		c_models[i].idx = i
	end

	for i=0, n_vars-1 do
		vars[i+1]._ptr = c_vars+i
		c_vars[i].idx = i
	end

	for _,src in ipairs(models) do
		local m = src._ptr

		m.k = src.k
		m.c = src.c

		create_checks(m, src.checks, arena)

		-- TODO
		m.may_fail = 1

		m.n_param = #src.params
		m.params = C.arena_malloc(arena, ffi.sizeof("struct fhk_var *[?]", m.n_param))
		for i,p in ipairs(src.params) do
			m.params[i-1] = p._ptr
		end
	end

	for _,src in ipairs(vars) do
		local v = src._ptr

		v.n_mod = #src.models
		v.models = C.arena_malloc(arena, ffi.sizeof("struct fhk_model *[?]", v.n_mod))
		for i,m in ipairs(src.models) do
			v.models[i-1] = m._ptr
		end
	end

	local G = ffi.gc(C.arena_malloc(arena, ffi.sizeof("struct fhk_graph")), function()
		C.arena_destroy(arena)
	end)

	G = ffi.cast("struct fhk_graph *", G)
	G.n_var = n_vars
	G.n_mod = n_models

	C.fhk_graph_init(G)

	return {
		G=G,
		models=models,
		c_models=c_models,
		vars=vars,
		c_vars=c_vars
	}
end

return {
	read=read,
	get_fhk_graph=get_fhk_graph,
	get_lexicon=get_lexicon
}
