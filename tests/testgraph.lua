local alloc = require "alloc"
local fhk = require "fhk"
local groupof = require("fhk.graph").groupof
local ctypes = require "fhk.ctypes"
local ffi = require "ffi"
local C = ffi.C

local IDENT   = "@ident"
local SPACE   = "@space"
local DEFAULT = ""
local NA      = "na"

local function def()
	return {
		models  = {}, -- [name] -> model
		groups  = {}, -- [name] -> true
		vars    = {}, -- [name] -> var
		shadows = {}, -- [name] -> shadow
		umaps   = {}, -- [ufunc] -> true
	}
end

local function var(name, ctype)
	return {
		name  = name,
		group = groupof(name),
		ctype = ffi.typeof(ctype or "double")
	}
end

local function model(name)
	return {
		name    = name,
		group   = groupof(name),
		k       = 0,
		c       = 1,
		params  = {},
		returns = {},
		shadows = {}
	}
end

local function edge(name, map)
	return {
		name = name,
		map  = map
	}
end

local function shedge(name, map, penalty)
	return {
		name    = name,
		map     = map,
		penalty = penalty
	}
end

local function ufunc(func, flags)
	return {
		func    = func,
		flags   = flags or "i"
	}
end

local function umap(map, inverse)
	return {
		map     = map,
		inverse = inverse
	}
end

local function umap_undeclared(name)
	local f = ufunc(function()
		error(string.format("undeclared umap: %s", name))
	end, "k")

	return umap(f, f)
end

local function isconst(flags)
	return flags:match("k")
end

local function isnonconst(flags)
	return flags:match("i")
end

local function isbuiltinmap(map)
	return map == IDENT or map == SPACE or map == DEFAULT
end

local function toname(name)
	return name:match("#") and name or ("default#"..name)
end

local function include_group(def, name)
	def.groups[name] = true
end

local function include_var(def, name)
	if not def.vars[name] then
		def.vars[name] = var(name)
		include_group(def, def.vars[name].group)
	end
end

local function include_map(def, map)
	if isbuiltinmap(map) then
		return
	end

	if not def.umaps[map] then
		def.umaps[map] = umap_undeclared(map)
	end
end

local function add_model(def, m)
	if def.models[m.name] then
		error(string.format("duplicate model: '%s'", m.name))
	end

	include_group(def, m.group)

	for _,e in ipairs(m.params) do
		include_map(def, e.map)
		include_var(def, e.name)
	end

	for _,e in ipairs(m.returns) do
		include_map(def, e.map)
		include_var(def, e.name)
	end

	for _,e in ipairs(m.shadows) do
		include_map(def, e.map)
		if not def.shadows[e.name] then
			error(string.format("no shadow named '%s' (refd by model '%s')", e.name, m.name))
		end
	end

	def.models[m.name] = m
end

local function add_shadow(def, s)
	if def.shadows[s.name] then
		error(string.format("duplicate shadow: '%s'", s.name))
	end

	include_var(def, s.var_name)

	def.shadows[s.name] = s
end

local function add_var(def, var)
	if def.vars[var.name] then
		error(string.format("duplicate var: '%s'", var.name))
	end

	def.vars[var.name] = var
end

local guards = {
	[">="] = {
		[tonumber(ffi.typeof "double")] = {guard=C.FHKC_GEF64, dtype="f64"},
		[tonumber(ffi.typeof "float")]  = {guard=C.FHKC_GEF32, dtype="f32"},
	},
	["<="] = {
		[tonumber(ffi.typeof "double")] = {guard=C.FHKC_LEF64, dtype="f64"},
		[tonumber(ffi.typeof "float")]  = {guard=C.FHKC_LEF32, dtype="f32"}
	},
	["&"] = {
		[tonumber(ffi.typeof "uint8_t")] = {guard=C.FHKC_U8_MASK64, dtype="u64"}
	}
}
local function toguard(shadow, ctype)
	local g = guards[shadow.guard][tonumber(ctype)]
	return g.guard, ffi.new("fhk_shvalue", {[g.dtype]=shadow.arg})
end

local function dsyms(mapping)
	local nm, nx = 0, 0
	local syms = {}

	for idx,x in pairs(mapping) do
		if type(idx) == "number" then
			if idx < 0 then nm = nm+1 else nx = nx+1 end
			syms[idx] = x.name
		end
	end

	local s = ffi.new("const char *[?]", nm+nx)

	for idx,name in pairs(syms) do
		(s+nm)[idx] = ffi.string(name)
	end

	return s, syms
end

local function builtinextmap(map, from, to)
	if map == IDENT then return C.FHKMAP_IDENT end
	if map == SPACE then return C.FHKMAP_SPACE end
	if map == DEFAULT then return groupof(from) == groupof(to) and C.FHKMAP_IDENT or C.FHKMAP_SPACE end
	error(string.format("not a builtin map: %s", map))
end

local function tomap(map, umaps, uobj, from, to)
	local umap = umaps[map]
	if umap then
		return ctypes.map_user(uobj[umap.map], uobj[umap.inverse])
	else
		return builtinextmap(map, from, to)
	end
end

local function addufunc(uf, uobj, umin, umax)
	if not uobj[uf] then
		local pos
		if isnonconst(uf.flags) then
			umin, pos = umin-1, umin-1
		else
			umax, pos = umax+1, umax
		end
		uobj[uf] = pos
		uobj[pos] = uf
	end
	return umin, umax
end

local function build(def)
	local objs = { g = {}, u = {} }

	local gnum = 0
	for name,_ in pairs(def.groups) do
		objs.g[name] = gnum
		objs.g[gnum] = name
		gnum = gnum+1
	end

	local umin, umax = 0, 0
	for _,umap in pairs(def.umaps) do
		umin, umax = addufunc(umap.map, objs.u, umin, umax)
		umin, umax = addufunc(umap.inverse, objs.u, umin, umax)
	end

	local D = ffi.gc(C.fhk_create_def(), C.fhk_destroy_def)

	for _,v in pairs(def.vars) do
		objs[v] = D:add_var(objs.g[v.group], ffi.sizeof(v.ctype))
	end

	for _,s in pairs(def.shadows) do
		local guard, arg = toguard(s, def.vars[s.var_name].ctype)
		objs[s] = D:add_shadow(objs[def.vars[s.var_name]], guard, arg)
	end

	for _,m in pairs(def.models) do
		local obj = D:add_model(objs.g[m.group], m.k, m.c, m.cmin or m.k)
		objs[m] = obj

		for _,e in ipairs(m.params) do
			D:add_param(obj, objs[def.vars[e.name]], tomap(e.map, def.umaps, objs.u, m.name, e.name))
		end

		for _,e in ipairs(m.returns) do
			D:add_return(obj, objs[def.vars[e.name]], tomap(e.map, def.umaps, objs.u, m.name, e.name))
		end

		for _,e in ipairs(m.shadows) do
			D:add_check(obj, objs[def.shadows[e.name]], tomap(e.map, def.umaps, objs.u, m.name, e.name),
				e.penalty)
		end
	end

	local idx = { g = objs.g, u = objs.u }
	for x,o in pairs(objs) do
		if type(x) ~= "string" then
			idx[x] = D:idx(o)
			idx[idx[x]] = x
		end
	end

	local syms = nil

	local G = ffi.gc(D:build(), function(G)
		C.fhk_destroy_graph(G)
		syms = nil
	end)

	if C.fhk_is_debug() then
		-- we can ignore the sym table, the strings are referenced by def
		syms = dsyms(idx)
		C.fhk_set_dsym(G, syms+G.nm)
	end

	return G, idx
end

local function decl_var(decl)
	local v = var(toname(decl[1]), decl.ctype)
	return function(def)
		add_var(def, v)
	end
end

local function parse_bitset(src)
	local ret = 0ULL

	for b in src:gmatch("%d+") do
		local val = tonumber(b)
		if val >= 64 then
			error(string.format("bit out of range: %d", val))
		end
		ret = bit.bor(ret, bit.lshift(1ULL, val))
	end

	return ret
end

local function parse_shadow(src)
	local var, guard, arg = src:match("^([%w#_%-]+)([><&]=?)(.+)$")
	if not (var and guard and arg) then
		error(string.format("shadow syntax error: %s", src))
	end

	if guard == ">=" or guard == "<=" then
		arg = tonumber(arg) or error(string.format("malformed number: %s", arg))
	elseif guard == "&" then
		arg = parse_bitset(arg)
	else
		error(string.format("invalid guard: %s", guard))
	end

	return {
		var_name = toname(var),
		guard    = guard,
		arg      = arg
	}
end

local function decl_shadow(decl)
	decl = type(decl) == "string" and {decl} or decl
	local shadow = parse_shadow(decl[1])
	shadow.name = toname(decl.name or decl[1])
	return function(def)
		add_shadow(def, shadow)
	end
end

local function parse_check(src)
	local shadow, map, penalty = src:match("^([^:%+]+):?([^%+]*)%+?([einf%d%.]*)$")
	if map == "" then map = IDENT end
	penalty = penalty == "" and math.huge or tonumber(penalty)

	if not (shadow and map and penalty) then
		error(string.format("check edge syntax error: %s", src))
	end

	local ret = shedge(toname(shadow), map, penalty)

	if not shadow:match("^[%w#_%-]+$") then
		ret.def = parse_shadow(shadow)
		ret.def.name = ret.name
	end

	return ret
end

local function parse_edges(dest, src)
	for name,map in src:gmatch("([^,:]+):?([^,]*)") do
		table.insert(dest, edge(toname(name), map))
	end
end

local function wrapmodf(f)
	return function(cm)
		local p = {}
		local e = cm.edges+0

		for i=1, cm.np do
			local ptr = ffi.cast("double *", e.p)
			p[i] = {}
			for j=1, tonumber(e.n) do
				p[i][j] = ptr[j-1]
				--print("->", p[i][j])
			end
			e = e+1
		end

		local r = {f(unpack(p))}

		if #r ~= cm.nr then
			error(string.format("expected %d return values, got %d", cm.nr, #r))
		end

		for i, ri in ipairs(r) do
			local rp = ffi.cast("double *", e.p)
			for j=1, #ri do
				rp[j-1] = ri[j]
				--print("<-", ri[j])
			end
			e = e+1
		end
	end
end

local function tomodf(f)
	if type(f) == "table" and #f > 0 then return function() return unpack(f) end end
	if type(f) == "number" then return function() return {f} end end
	return f
end

local function wrapmapf(f)
	return function(inst, ...)
		return fhk.subset(f(inst), ...)
	end
end

local function decl_model(decl)
	decl = type(decl) == "string" and {decl} or decl
	local signature = decl[1]:gsub("%s", "")

	local m = model(toname(decl.name or decl[1]))
	m.f = wrapmodf(tomodf(decl[2]))
	m.k = decl.k or m.k
	m.c = decl.c or m.c

	local params, returns = signature:gsub("^[^#]+#", ""):match("([%w#_%-:@,]*)%->([%w#_%-:@,]*)")
	if not (params and returns) then
		error(string.format("signature syntax error: %s", signature))
	end

	parse_edges(m.params, params)
	parse_edges(m.returns, returns)

	for s in signature:gmatch("%[(.-)%]") do
		table.insert(m.shadows, parse_check(s))
	end

	return function(def)
		for _,c in ipairs(m.shadows) do
			if c.def then
				add_shadow(def, c.def)
			end
		end

		add_model(def, m)
	end
end

local function decl_umap(decl)
	local name, map, inverse = unpack(decl)
	return function(def)
		def.umaps[name] = umap(map, inverse)
	end
end

local function decl_graph(decl)
	local def = def()

	for _,df in ipairs(decl) do
		df(def)
	end

	return def
end

local function defidx(values)
	local idx = {}

	for i,v in ipairs(values) do
		if v ~= NA then
			table.insert(idx, i-1)
		end
	end

	return idx
end

local function driver(S, mapping)
	local arena = alloc.arena()

	while true do
		local status = S:continue()
		local code, arg = fhk.status(status)

		if code == C.FHK_OK then
			return
		end

		if code == C.FHK_ERROR then
			error("TODO (mapping.syms)")
		end

		if code == C.FHKS_SHAPE then
			assert(false) -- shape table should be pregiven
		elseif code == C.FHKS_MAPCALL then
			local mref = arg.s_mapcall
			S:setmap(mref.idx, mref.inst, mapping.u[mref.idx].func(mref.inst, arena))
		elseif code == C.FHKS_VREF then
			local vref = arg.s_vref
			error(string.format("solver tried to evaluate non-given variable: %s:%d",
				mapping[vref.idx].name, vref.inst))
		elseif code == C.FHKS_MODCALL then
			local mc = arg.s_modcall
			mapping[mc.mref.idx].f(mc)
		end
	end
end

local function infershape(mapping, n, ...)
	for _,vs in ipairs({...}) do
		for name,values in pairs(vs) do
			local nv = values.n or #values
			local group = groupof(toname(name))
			if n[group] then
				if n[group] ~= nv then
					error(string.format("group %s has size %d but variable %s has %d values",
						group, n[group], name, nv))
				end
			else
				n[group] = nv
			end
		end
	end

	local shape = {}
	for num,group in pairs(mapping.g) do
		if type(num) == "number" then
			shape[num] = n[group] or error(string.format("can't infer shape for group %s", group))
		end
	end

	return shape
end

local function check_solution(G, ng, meta)
	local bufs, indices = {}, {}
	local arena = alloc.arena()
	local S = C.fhk_create_solver(G, arena)

	for name,values in pairs(meta.solution) do
		local x = meta.def.vars[toname(name)]
		indices[name] = defidx(values)
		bufs[name] = ffi.new(ffi.typeof("$[?]", x.ctype), #indices[name])
		S:setroot(meta.mapping[x], fhk.subset(indices[name], arena), bufs[name])
	end

	local shape = infershape(meta.mapping, ng, meta.solution, meta.given)
	for g,n in pairs(shape) do
		S:setshape(g, n)
	end

	if meta.given then
		for name, values in pairs(meta.given) do
			name = toname(name)
			local xi = meta.mapping[meta.def.vars[name]]

			if values.n then
				S:setvaluei(xi, 0, values.n, values.buf)
			else
				local buf = ffi.new(ffi.typeof("$[1]", meta.def.vars[name].ctype))
				for i,v in ipairs(values) do
					if v ~= NA then
						buf[0] = v
						S:setvaluei(xi, i-1, 1, buf)
					end
				end
			end
		end
	end

	driver(S, meta.mapping)

	for name,truth in pairs(meta.solution) do
		local solved = bufs[name]

		for i,j in ipairs(indices[name]) do
			if truth[j+1] ~= solved[i-1] then
				error(string.format("wrong solution: %s:%d expected %s, got %s (%f)",
					name, j, truth[j+1], solved[i-1], solved[i-1]))
			end
		end
	end
end

local function check_prune(G, meta)
	local P = C.fhk_create_prune(G)
	local flags = P:flags()

	if meta.given then
		for _,name in ipairs(meta.given) do
			name = toname(name)
			local idx = meta.mapping[meta.def.vars[name]]
			flags[idx] = bit.bor(flags[idx], C.FHKF_GIVEN)
		end
	end

	for _,name in ipairs(meta.retain) do
		name = toname(name)
		local idx = meta.mapping[meta.def.vars[name] or meta.def.models[name]]
		flags[idx] = bit.bor(flags[idx], C.FHKF_SELECT)
	end

	P()

	local bounds = P:bounds()

	for i=-G.nm, G.nv-1 do
		local name = meta.mapping[i].name

		if bit.band(flags[i], C.FHKF_SELECT) == 0 and meta.selected[name] then
			error(string.format("%s should be selected, but it was pruned", name))
		elseif bit.band(flags[i], C.FHKF_SELECT) ~= 0 and not meta.selected[name] then
			error(string.format("%s should be pruned, but it was selected: [%f, %f]",
				name, bounds[i][0], bounds[i][0]))
		end

		local b = meta.selected[name]
		if type(b) == "table" and (
			(type(b[1]) == "number" and bounds[i][0] ~= b[1])
			or (type(b[2]) == "number" and bounds[i][1] ~= b[2])) then

			error(string.format("%s should have bounds [%s, %s], but they are: [%f, %f]",
				name,
				type(b[1]) == "number" and b[1] or "any",
				type(b[2]) == "number" and b[2] or "any",
				bounds[i][0],
				bounds[i][1]
			))
		end
	end

	C.fhk_destroy_prune(P)
end

local function inject(env)
	env.v = decl_var
	env.s = decl_shadow
	env.m = decl_model
	env.u = decl_umap
	env.n = {}
	env.na = NA
	env.ufunc = function(f, flags) return ufunc(wrapmapf(f), flags) end

	env.graph = function(decl)
		local def = decl_graph(decl)
		local G, mapping = build(def)
		env.G = G
		env.meta = {
			def     = def,
			mapping = mapping
		}
	end

	env.given = function(decl)
		env.meta.given = decl
	end

	env.retain = function(decl)
		env.meta.retain = decl
	end

	env.solution = function(decl)
		env.meta.solution = decl
		check_solution(env.G, env.n, env.meta)
	end

	env.selected = function(decl)
		local selected = {}
		for name,v in pairs(decl) do
			if type(name) == "number" then
				selected[toname(v)] = true
			else
				selected[toname(name)] = v
			end
		end
		env.meta.selected = selected
		check_prune(env.G, env.meta)
	end
end

return function(f)
	local env = setmetatable({}, {__index=_G})
	inject(env)
	return setfenv(f, env)
end
