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

local function arena_copystring(a, s)
	local ret = C.arena_malloc(a, #s+1)
	ffi.copy(ret, s)
	return ret
end

-- TODO: fhk graph should use this lexicon
local function get_lexicon(data)
	local types = {} -- TODO
	local vars = collect(data.vars)
	local objs = collect(data.objs)

	local arena = C.arena_create(1024)
	local lex = ffi.gc(C.lex_create(#types, #vars, #objs), function(lex)
		C.lex_destroy(lex)
		C.arena_destroy(arena)
	end)

	for i,v in ipairs(vars) do
		v._lexid = i-1
		v._ptr = lex.vars.data + v._lexid

		local cv = v._ptr
		cv.name = arena_copystring(arena, v.name)
		if not builtin_types[v.type] then
			error(string.format("No definition for type '%s' of variable '%s'",
				v.type, v.name))
		end
		cv.type = builtin_types[v.type]
	end

	for i,o in ipairs(objs) do
		o._lexid = i-1
		o._ptr = lex.objs.data + o._lexid
	end

	for i,o in ipairs(objs) do
		o._ptr.name = arena_copystring(arena, o.name)

		if o.fields then
			local fs = ffi.new("lexid[?]", #o.fields)
			for j,f in ipairs(o.fields) do
				fs[j-1] = data.vars[f]._lexid
			end
			C.lex_set_vars(lex, o._lexid, #o.fields, fs)
		end

		if o.uprefs then
			local us = ffi.new("lexid[?]", #o.uprefs)
			for j,u in ipairs(o.uprefs) do
				us[j-1] = data.objs[u]._lexid
			end
			C.lex_set_uprefs(lex, o._lexid, #o.uprefs, us)
		end
	end

	C.lex_compute_refs(lex)

	return lex
end

local function make_lookup(xs, n, ret)
	ret = ret or {}

	for i=0, n-1 do
		local x = xs+i
		local name = ffi.string(x.name)
		ret[name] = x
	end

	return ret
end

local function link_graph(fhk_models, var_defs)
	local vars = setmetatable({}, {__index=function(t,k)
		local p = var_defs[k]
		if not p then
			error(string.format("No variable definition for var '%s'", k))
		end

		t[k] = { def=p, models={} }
		return t[k]
	end})

	local models = {}

	for k,v in pairs(fhk_models) do
		local m = {
			model=v,
			params={},
			checks={}
		}

		for _,p in ipairs(v.params) do
			table.insert(m.params, vars[p])
		end

		for _,c in ipairs(v.checks) do
			table.insert(m.checks, {check=c, var=vars[c.var]})
		end

		local r = vars[v.returns]
		table.insert(r.models, m)
		m.returns = r
		models[k] = m
	end

	return models, vars
end

local function create_einfo(model, params, ret, impl)
	if impl.lang ~= "R" then
		error("sorry only R")
	end

	local argt = ffi.new("enum ptype[?]", #params)
	for i,p in ipairs(params) do
		argt[i-1] = C.tpromote(params[i].def.type)
	end

	local rett = ffi.new("enum ptype[1]")
	rett[0] = C.tpromote(ret.def.type)

	return C.ex_R_create(
		impl.file, impl.func,
		#params, argt, 1, rett
	)
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

local function copy_set_cst(check, vdef, values)
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
		copy_set_cst(check, vdef, cst.values)
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
		c.var = checks[i+1].var.ptr
		local src = checks[i+1].check
		c.costs[C.FHK_COST_IN] = src.cost_in
		c.costs[C.FHK_COST_OUT] = src.cost_out
		copy_cst(c, checks[i+1].var.def, src.cst)
	end
end

local function create_graph(models, vars)
	models = collect(models)
	vars = collect(vars)

	local arena = C.arena_create(1024)

	local n_models = #models
	local n_vars = #vars

	local c_models = ffi.cast("struct fhk_model *", C.arena_malloc(arena,
		ffi.sizeof("struct fhk_model[?]", n_models)))
	local c_models_meta = ffi.cast("struct fhk_model_meta *", C.arena_malloc(arena,
		ffi.sizeof("struct fhk_model_meta[?]", n_models)))
	local c_vars = ffi.cast("struct fhk_var *", C.arena_malloc(arena,
		ffi.sizeof("struct fhk_var[?]", n_vars)))

	for i=0, n_models-1 do
		models[i+1].ptr = c_models+i
		models[i+1].metaptr = c_models_meta+i
		c_models[i].idx = i
	end

	for i=0, n_vars-1 do
		vars[i+1].ptr = c_vars+i
		c_vars[i].idx = i
	end

	for _,src in ipairs(models) do
		local m = src.ptr
		local meta = src.metaptr

		m.k = src.model.k
		m.c = src.model.c

		create_checks(m, src.checks, arena)

		-- TODO
		m.may_fail = 1

		m.n_param = #src.params
		m.params = C.arena_malloc(arena, ffi.sizeof("struct fhk_var *[?]", m.n_param))
		for i,p in ipairs(src.params) do
			m.params[i-1] = p.ptr
		end

		m.udata = meta
		meta.name = arena_copystring(arena, src.model.name)
		meta.ex = create_einfo(m, src.params, src.returns, src.model.impl)
	end

	for _,src in ipairs(vars) do
		local v = src.ptr
		-- TODO: type

		v.n_mod = #src.models
		v.models = C.arena_malloc(arena, ffi.sizeof("struct fhk_model *[?]", v.n_mod))
		for i,m in ipairs(src.models) do
			v.models[i-1] = m.ptr
		end

		v.udata = src.def
	end

	local G = ffi.gc(C.arena_malloc(arena, ffi.sizeof("struct fhk_graph")), function()
		for i=0, n_models-1 do
			local ex = c_models_meta[i].ex
			ex.impl.destroy(ex)
		end
		C.arena_destroy(arena)
	end)

	G = ffi.cast("struct fhk_graph *", G)
	G.n_var = n_vars
	G.n_mod = n_models

	C.fhk_graph_init(G)

	return {
		G=G,
		models=c_models,
		vars=c_vars
	}
end

local function get_fhk_graph(data, lex)
	local var_defs = {}

	for i=0, tonumber(lex.vars.n)-1 do
		local var = lex.vars.data+i
		var_defs[ffi.string(var.name)] = var
	end

	local models, vars = link_graph(data.fhk_models, var_defs)
	return create_graph(models, vars)
end

return {
	newconf=newconf,
	get_fhk_graph=get_fhk_graph,
	get_lexicon=get_lexicon
}
