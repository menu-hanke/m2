local typing = require "typing"
local exec = require "exec"
local fhk = require "fhk"
local ffi = require "ffi"
local C = ffi.C

local function newconf()
	local conf_env = get_builtin_file("conf_env.lua")
	local env, data = dofile(conf_env)
	return env, data
end

local function patch_enum_values(data)
	for name,t in pairs(data.types) do
		if t.kind == "enum" then
			local maxv = 0

			for _,i in pairs(t.def) do
				if i > maxv then
					maxv = i
				end
			end

			if maxv >= 64 then
				error(string.format("%s: enum values >64 not yet implemented", name))
			end

			t.type = C.tfitenum(maxv)

			for k,i in pairs(t.def) do
				t.def[k] = C.packenum(i)
			end
		end
	end
end

local function resolve_dt(data, xs)
	for _,x in pairs(xs) do
		local dtype = x.type

		if typing.builtin_types[dtype] then
			x.type = typing.builtin_types[dtype]
		elseif data.types[dtype] then
			x.type = data.types[dtype].type
		else
			error(string.format("No definition found for type '%s' of '%s'",
				dtype, x.name))
		end
	end
end

local function resolve_types(data)
	patch_enum_values(data)
	resolve_dt(data, data.envs)
	resolve_dt(data, data.vars)
	for _,o in pairs(data.objs) do
		resolve_dt(data, o.vars)
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

		for i,r in ipairs(m.returns) do
			local fv = fhk_vars[r]
			if not fv then
				error(string.format("No definition found for var '%s' (return value of model '%s')",
					r, m.name))
			end

			m.returns[i] = fv
			m.returns[r] = nil
			table.insert(fv.models, m)
		end
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

local function create_fhk_graph(data)
	local arena = C.arena_create(4096)

	local models = collect(data.fhk_models)
	local vars = collect(data.fhk_vars)
	local G = ffi.gc(C.fhk_alloc_graph(arena, #vars, #models),
		function() C.arena_destroy(arena) end)

	for i,m in ipairs(models) do
		m.fhk_model = C.fhk_get_model(G, i-1)
		m.ex_func = exec.from_model(m)
	end

	for i,v in ipairs(vars) do
		v.fhk_var = C.fhk_get_var(G, i-1)
	end

	fhk.init_fhk_graph(arena, data)

	return G
end

return {
	read=read,
	create_lexicon=create_lexicon,
	create_fhk_graph=create_fhk_graph
}
