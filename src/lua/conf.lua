local typing = require "typing"
local ffi = require "ffi"
local C = ffi.C

local function newconf()
	local conf_env = get_builtin_file("conf_env.lua")
	local env, data = dofile(conf_env)
	return env, data
end

local function resolve_dt(xs)
	for _,x in pairs(xs) do
		local dtype = x.type
		if not typing.builtin_types[dtype] then
			error(string.format("No definition found for type '%s' of '%s'",
				dtype, x.name))
		end

		x.type = typing.builtin_types[dtype]
		
		-- TODO: non-builtins
	end
end

local function resolve_types(data)
	resolve_dt(data.envs)
	resolve_dt(data.vars)
	for _,o in pairs(data.objs) do
		resolve_dt(o.vars)
	end
end

local function link_graph(data)
	local fhk_vars = setmetatable({}, {__index=function(self,k)
		self[k] = { models={} }
		return self[k]
	end})

	for _,o in pairs(data.objs) do
		for _,v in pairs(o.vars) do
			fhk_vars[v.name].src = v
			fhk_vars[v.name].kind = "var"
		end
	end

	for _,e in pairs(data.envs) do
		fhk_vars[e.name].src = e
		fhk_vars[e.name].kind = "env"
	end

	for _,v in pairs(data.vars) do
		fhk_vars[v.name].src = v
		fhk_vars[v.name].kind = "computed"
	end

	setmetatable(fhk_vars, nil)

	for _,m in pairs(data.fhk_models) do
		for i,p in ipairs(m.params) do
			local fv = fhk_vars[p]
			if not fv then
				error(string.format("No definition found for var '%s' (parameter of model '%s')",
					p, m.name))
			end

			m.params[i] = fv
			-- delete named version, only used for dupe checking in conf_env
			m.params[p] = nil
		end

		for i,c in ipairs(m.checks) do
			local fv = fhk_vars[c.var]
			if not fv then
				error(string.format("No definition found for var '%s' (constraint of model '%s')",
					c.var, m.name))
			end

			c.var = fv
		end

		local rv = fhk_vars[m.returns]
		if not rv then
			error(string.format("No definition found for var '%s' (return value of model '%s')",
				m.returns, m.name))
		end

		m.returns = rv
		table.insert(rv.models, m)
	end

	data.fhk_vars = fhk_vars
end

local function verify_names(data)
	local _used = {}
	local used = setmetatable({}, {__newindex=function(_, k, v)
		if _used[k] then
			error(string.format("Duplicate definition of name '%s'", k))
		end
		_used[k] = v
	end})

	for _,o in pairs(data.objs) do
		used[o.name] = true
		for _,v in pairs(o.vars) do
			used[v.name] = true
		end
	end

	for _,e in pairs(data.envs) do
		used[e.name] = true
	end

	for _,v in pairs(data.vars) do
		used[v.name] = true
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
	verify_names(data)
	verify_models(data)

	return data
end

local function create_lexicon(data)
	local arena = C.arena_create(1024)
	local lex = ffi.gc(C.lex_create(), function(lex)
		C.arena_destroy(arena)
		C.lex_destroy(lex)
	end)

	for _,o in pairs(data.objs) do
		local lo = C.lex_add_obj(lex)
		o.lexobj = lo
		lo.name = arena_copystring(arena, o.name)
		lo.resolution = o.resolution

		for _,v in pairs(o.vars) do
			local lv = C.lex_add_var(lo)
			v.lexvar = lv
			lv.name = arena_copystring(arena, v.name)
			lv.type = v.type
		end
	end

	for _,e in pairs(data.envs) do
		local le = C.lex_add_env(lex)
		e.lexenv = le
		le.name = arena_copystring(arena, e.name)
		le.resolution = e.resolution
		le.type = e.type
	end

	data.lex = lex
	return lex
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
		c.var = check.var.fhk_var
		c.costs[C.FHK_COST_IN] = check.cost_in
		c.costs[C.FHK_COST_OUT] = check.cost_out
		copy_cst(c, check.var.src, check.cst)
	end
end

local function create_fhk_graph(data)
	local arena = C.arena_create(4096)

	local models = collect(data.fhk_models)
	local vars = collect(data.fhk_vars)
	local n_models = #models
	local n_vars = #vars

	local c_models = ffi.cast("struct fhk_model *", C.arena_malloc(arena,
		ffi.sizeof("struct fhk_model[?]", n_models)))
	local c_vars = ffi.cast("struct fhk_var *", C.arena_malloc(arena,
		ffi.sizeof("struct fhk_var[?]", n_vars)))

	for i=0, n_models-1 do
		models[i+1].fhk_model = c_models+i
		c_models[i].idx = i
	end

	for i=0, n_vars-1 do
		vars[i+1].fhk_var = c_vars+i
		c_vars[i].idx = i
	end

	for _,m in ipairs(models) do
		local fm = m.fhk_model

		fm.k = m.k
		fm.c = m.c

		create_checks(fm, m.checks, arena)

		-- TODO
		fm.may_fail = 1

		fm.n_param = #m.params
		fm.params = C.arena_malloc(arena, ffi.sizeof("struct fhk_var *[?]", fm.n_param))
		for i,p in ipairs(m.params) do
			fm.params[i-1] = p.fhk_var
		end
	end

	for _,v in ipairs(vars) do
		local fv = v.fhk_var

		fv.n_mod = #v.models
		fv.models = C.arena_malloc(arena, ffi.sizeof("struct fhk_model *[?]", fv.n_mod))
		for i,m in ipairs(v.models) do
			fv.models[i-1] = m.fhk_model
		end
	end

	local G = ffi.gc(C.arena_malloc(arena, ffi.sizeof("struct fhk_graph")), function()
		C.arena_destroy(arena)
	end)

	G = ffi.cast("struct fhk_graph *", G)
	G.n_var = n_vars
	G.n_mod = n_models

	C.fhk_graph_init(G)

	return G
end

return {
	read=read,
	create_lexicon=create_lexicon,
	create_fhk_graph=create_fhk_graph
}
