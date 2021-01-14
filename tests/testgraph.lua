local fhk = require "fhk" -- for metatypes
local alloc = require "alloc"
local misc = require "misc"
local ffi = require "ffi"
local C = ffi.C

local def_mt = { __index={} }

local function def(g)
	local d = setmetatable({
		models = {}, -- [name] -> model
		groups = {}, -- {group}
		maps   = {}  -- [name] -> map
	}, def_mt)

	if g then
		for _,a in ipairs(g) do
			a(d)
		end
	end

	return d
end

-- [name] -> { idx, size }
function def_mt.__index:assign_groups()
	local defgroup = {idx=#self.groups, size=1}
	local groups = setmetatable({}, { __index = function(self, name)
		self[name] = defgroup
		return defgroup
	end})

	for i,g in misc.ipairs0(self.groups) do
		local group = {idx=i, size=g.size or error("size missing from group definition")}
		for _,name in ipairs(g) do
			if rawget(groups, name) then
				error(string.format("Name '%s' belongs to multiple groups", name))
			end
			groups[name] = group
		end
	end

	return groups
end

---- models ----------------------------------------

local m_mt = { __index={k=1, c=2} }

---> nil    : default
---> number : builtin
---> string : usermap
local function parsemap(p)
	if p == "" then return end
	if p == "@ident" then return C.FHKM_IDENT end
	if p == "@space" then return C.FHKM_SPACE end
	if type(p) == "string" then return p end
	error(string.format("not a mapdef: %s", p))
end

-- edge  :: var[:subset]
local function splitedges(s)
	local r = {}
	for name,p in s:gmatch("([^,:]+):?([^,]*)") do
		table.insert(r, {name=name, map=parsemap(p)})
	end
	return r
end

local function tofunc(f)
	if type(f) == "table" and #f > 0 then return function() return unpack(f) end end
	if type(f) == "number" then return function() return {f} end end
	return f -- hope it's something callable
end

local function m(opt)
	local def = opt.def or opt[1]
	local p, r, name = def:gsub("%s", ""):match("^(.-)%->([^#]*)#?(.-)$")

	if not p then
		error(string.format("syntax error (model): %s", def))
	end

	return setmetatable({
		params  = splitedges(p),
		returns = splitedges(r),
		name    = (name ~= "") and name or def,
		k       = opt.k,
		c       = opt.c,
		checks  = {},
		f       = tofunc(opt.f or opt[2])
	}, m_mt)
end

-- cmp :: edge[><]=num+penalty
-- set :: edge{set}+penalty
function m_mt.__index:check(def)
	local ds = def:gsub("%s", "")
	local name, map, cmp, arg, penalty = ds:match("([^:]+):?([^><]-)([><])=([%d%.]+)%+([einf%d%.]+)")
	if name then
		table.insert(self.checks, {
			name    = name,
			map     = parsemap(map),
			cst     = ffi.new("fhk_cst", {
				op = cmp == ">" and C.FHKC_GEF64 or C.FHKC_LEF64,
				arg = { f64 = tonumber(arg) },
				penalty = tonumber(penalty)
			})
		})

		return self
	end

	-- TODO: non-double checks

	error(string.format("syntax error (constraint): %s", def))
end

function m_mt:__call(def)
	if def.models[self.name] then
		error(string.format("Duplicate model: %s", self.name))
	end

	def.models[self.name] = self
end

---- groups ----------------------------------------

local function g(opt)
	return function(def)
		table.insert(def.groups, opt)
	end
end

---- maps ----------------------------------------

local function p(opt)
	local name, map, inverse = unpack(opt)
	return function(def)
		def.maps[name] = {map, inverse}
	end
end

---- testgraph ----------------------------------------

local testgraph_mt = { __index={} }

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
			error(string.format("Expected %d return values, got %d", cm.nr, #r))
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

local function shape_table(groups)
	-- calculated back from the actual seen groups because of default groups etc.
	local seen = {}
	for _,g in pairs(groups) do
		if not seen[g] then
			seen[g] = true
			table.insert(seen, g)
		end
	end

	local stab = ffi.new("fhk_idx[?]", #seen)
	for _,g in ipairs(seen) do
		stab[g.idx] = g.size
	end

	return stab
end

local function testgraph(def)
	local groups = def:assign_groups()
	local D = ffi.gc(C.fhk_create_def(), C.fhk_destroy_def)
	local sym_var, sym_mod = {}, {}

	-- [name] -> idx
	local vars = setmetatable({}, {
		__index = function(self, name)
			-- TODO: non-double
			self[name] = D:add_var(groups[name].idx, ffi.sizeof("double"))
			sym_var[self[name]] = name
			return self[name]
		end
	})

	-- [name|idx] -> map
	local nmaps = 0
	local maps = setmetatable({}, {
		__index = function(self, name)
			local map = {idx=nmaps, maps=def.maps[name]}
			self[nmaps] = map
			self[name] = map
			nmaps = nmaps + 1
			return map
		end
	})

	local function map(p, from, to)
		if not p then
			if groups[from] ~= groups[to] then
				error(string.format("Default map between groups (%s->%s), use an explicit @ident",
					from, to))
			end

			return C.FHKM_IDENT
		end
		if type(p) == "string" then
			return C.FHKM_USER + maps[p].idx
		end
		return p
	end

	-- [name|idx] -> {f,idx}
	local models = {}

	for name,mod in pairs(def.models) do
		local idx = D:add_model(groups[name].idx, mod.k, mod.c)

		for _,e in ipairs(mod.params) do
			D:add_param(idx, vars[e.name], map(e.map, name, e.name))
		end

		for _,e in ipairs(mod.returns) do
			D:add_return(idx, vars[e.name], map(e.map, name, e.name))
		end

		for _,e in ipairs(mod.checks) do
			D:add_check(idx, vars[e.name], map(e.map, name, e.name), e.cst)
		end

		sym_mod[idx] = name
		models[idx] = {f=wrapmodf(mod.f), idx=idx}
		models[name] = models[idx]
	end

	local arena = alloc.arena(2^20)
	local G = ffi.cast("fhk_graph *", D:build(arena:malloc(D:size())))
	-- +1 because the tables are 0-indexed
	local dsym_var = ffi.new("const char *[?]", #sym_var+1, sym_var)
	local dsym_mod = ffi.new("const char *[?]", #sym_mod+1, sym_mod)
	G:set_dsym(dsym_var, dsym_mod)

	return setmetatable({
		G = G,
		arena = arena,
		shape_table = shape_table(groups),
		models = models,
		vars = setmetatable(vars, nil),
		maps = setmetatable(maps, nil),
		syms = {
			vars = sym_var,
			models = sym_mod,
			-- anchor these to prevent gc
			dsym_var, dsym_mod
		}
	}, testgraph_mt)
end

function testgraph_mt.__index:driver_loop(S)
	while true do
		local status = S:continue()
		local code, arg = fhk.status(status)

		if code == C.FHK_OK then
			return
		end

		if code == C.FHK_ERROR then
			return fhk.fmt_error(arg.s_ei, self.syms)
		end

		if code == C.FHKS_SHAPE then
			assert(false) -- shape table should be pregiven
		elseif code == C.FHKS_MAPCALL or code == C.FHKS_MAPCALLI then
			local idx = code - C.FHKS_MAPCALL + 1 -- mapcall->1, mapcalli->2
			local mp = arg.s_mapcall
			mp.ss[0] = self.maps[mp.idx].maps[idx](mp.instance)
		elseif code == C.FHKS_GVAL then
			local gv = arg.s_gval
			error(string.format("solver tried to evaluate non-given variable: %s:%d",
				self.syms.vars[gv.idx], gv.instance))
		elseif code == C.FHKS_MODCALL then
			local mc = arg.s_modcall
			self.models[mc.idx].f(mc)
		end
	end
end

function testgraph_mt.__index:solve(num, req)
	local solver = C.fhk_create_solver(self.G, self.arena, num, req)
	solver:shape_table(self.shape_table)

	if self.given_values then
		for _,v in ipairs(self.given_values) do
			local xi = self.vars[v.name]
			for idx, inst in misc.enumerate(fhk.ss_iter(v.ss)) do
				solver:give(xi, inst, v.buf+idx)
			end
		end
	end

	local err = self:driver_loop(solver)
	if err then error(err) end
end

function testgraph_mt.__index:reduce()
	local flags = self.arena:new("uint8_t", self.G.nv)
	ffi.fill(flags, self.G.nv)

	if self.given_names then
		for _, name in ipairs(self.given_names) do
			flags[self.vars[name]] = C.FHKR_GIVEN
		end
	end

	for _, name in ipairs(self.roots) do
		flags[self.vars[name]] = bit.bor(flags[self.vars[name]], C.FHKR_ROOT)
	end

	return self.G:reduce(self.arena, flags)
end

---- test callbacks ----------------------------------------

function testgraph_mt.__index:root(vs)
	assert(not self.roots)
	self.roots = vs
end

function testgraph_mt.__index:vsubset(def)
	if type(def) ~= "table" then
		def = {def}
	end

	local idx, values = {}, {}
	-- `def` may contain holes, so `pairs` must be used here
	for i,v in pairs(def) do
		table.insert(idx, i-1)
		table.insert(values, v)
	end

	local ss = fhk.subset(idx, self.arena)
	local buf = self.arena:new("double", #values)
	for i,v in misc.ipairs0(values) do
		buf[i] = v
	end

	return ss, buf
end

function testgraph_mt.__index:fixed_subspace(vs)
	local fixed = {}

	for name,def in pairs(vs) do
		local ss, buf = self:vsubset(def)
		table.insert(fixed, { name=name, ss=ss, buf=buf })
	end

	return fixed
end

-- given { "name1", "name2", ... }             -> mark as FHKR_GIVEN (leaf) for reduce()
-- given { name1={...}, name2={...}, ... }     -> give values for leaf variable (can be a partial
--                                                subset, missing values abort search)
function testgraph_mt.__index:given(vs)
	if #vs > 0 then
		self.given_names = vs
	else
		self.given_values = self:fixed_subspace(vs)
	end
end

function testgraph_mt.__index:solution(vs)
	local solution = self:fixed_subspace(vs)

	local req = self.arena:new("struct fhk_req", #solution)
	for i,v in misc.ipairs0(solution) do
		req[i].idx = self.vars[v.name]
		req[i].ss = v.ss
		req[i].buf = self.arena:new("double", fhk.ss_size(v.ss))
	end

	local solver, err = self:solve(#solution, req)

	for i,v in misc.ipairs0(solution) do
		local r_buf = ffi.cast("double *", req[i].buf)
		for idx,inst in misc.enumerate(fhk.ss_iter(v.ss)) do
			local rv = r_buf[idx]
			local sv = v.buf[idx]

			if rv ~= sv then
				error(string.format("wrong solution: %s:%d -- got %f, expected %f",
					v.name, inst, rv, sv))
			end
		end
	end
end

function testgraph_mt.__index:subgraph(names)
	local sub = self:reduce()

	assert(sub ~= ffi.NULL)

	-- names <= sub ?
	for _,name in ipairs(names) do
		if self.vars[name] then
			if sub.r_vars[self.vars[name]] == C.FHKR_SKIP then
				error(string.format("Variable '%s' not in subgraph", name))
			end
		else
			if sub.r_models[self.models[name].idx] == C.FHKR_SKIP then
				error(string.format("Model '%s' not in subgraph", name))
			end
		end
	end

	local iv, im = {}, {}
	for _,name in ipairs(names) do
		if self.vars[name] then iv[self.vars[name]] = true
		elseif self.models[name] then im[self.models[name].idx] = true
		else assert(false) end
	end

	-- sub <= names?
	for i=0, self.G.nv-1 do
		if sub.r_vars[i] ~= C.FHKR_SKIP and not iv[i] then
			error(string.format("Extra variable '%s' in subgraph", ffi.string(self.G.vars[i].udata.p)))
		end
	end

	for i=0, self.G.nm-1 do
		if sub.r_models[i] ~= C.FHKR_SKIP and not im[i] then
			error(string.format("Extra model '%s' in subgraph", ffi.string(self.G.models[i].udata.p)))
		end
	end
end

--------------------------------------------------------------------------------

local function inject(env)
	env.m = m
	env.g = g
	env.p = p
	env.graph = function(g)
		local t = testgraph(def(g))
		env.given = misc.delegate(t, t.given)
		env.root = misc.delegate(t, t.root)
		env.solution = misc.delegate(t, t.solution)
		env.subgraph = misc.delegate(t, t.subgraph)
		env.set = function(idx) return fhk.subset(idx, t.arena) end
	end
	return env
end

return function(f)
	return setfenv(f, inject({}))
end
