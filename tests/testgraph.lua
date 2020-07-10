require "fhk" -- for metatypes
local alloc = require "alloc" -- for malloc/free
local misc = require "misc"
local ffi = require "ffi"
local C = ffi.C

-- TODO: non-double vars

local __kind__ = {}

local m_mt = { __index={[__kind__] = "model"} }
local g_mt = { __index={[__kind__] = "group"} }
local s_mt = { __index={[__kind__] = "map"} }
local NA = {}

local function tofunc(f)
	if type(f) == "table" and #f > 0 then return function() return unpack(f) end end
	if type(f) == "number" then return function() return {f} end end
	return f -- hope it's something callable
end

-- edge  :: var[:subset]
local function splitedges(s)
	local r = {}
	for name, map in s:gmatch("([^,:]+):?([^,]*)") do
		table.insert(r, {name=name, map=map})
	end
	return r
end

-- model :: ep1,ep2,...epN->er1,er2,...,erN [@ name]
local function m(conf)
	local def = conf.def or conf[1]
	local p, r, name = def:gsub("%s", ""):match("^(.-)%->([^#]*)#?(.-)$")

	if not p then
		error(string.format("syntax error (model): %s", def))
	end

	return setmetatable({
		params  = splitedges(p),
		returns = splitedges(r),
		name    = (name ~= "") and name or def,
		k       = conf.k or 1,
		c       = conf.c or 2,
		checks  = {},
		f       = tofunc(conf.f or conf[2])
	}, m_mt)
end

local function g(def)
	return setmetatable(def, g_mt)
end

local function s(def)
	return setmetatable({
		name = def[1],
		map  = def[2],
		inverse = def[3]
	}, s_mt)
end

-- cmp :: edge[><]=num+penalty
-- set :: edge{set}+penalty
function m_mt.__index:check(def)
	local ds = def:gsub("%s", "")
	local name, map, cmp, arg, penalty = ds:match("([^:]+):?([^><]-)([><])=([%d%.]+)%+([einf%d%.]+)")
	if name then
		table.insert(self.checks, {
			name    = name,
			map     = map,
			op      = cmp == ">" and C.FHKC_GEF64 or C.FHKC_LEF64,
			arg     = ffi.new("fhk_arg", {f64=tonumber(arg)}),
			penalty = tonumber(penalty)
		})

		return self
	end

	-- this doesn't currently make sense because the test driver uses only doubles.
	-- commented because i didn't commit it yet and i don't want to rewrite the pattern...
	-- uncomment when test driver has proper type support.
	--[[
	local name, map, set, penalty = ds:match("([^:]+):?([^{]-){([%d%.,]+)}%+([einf%d%.]+)")
	if name then
		local mask = 0ULL
		for x in set:gmatch("[%d%.]+") do
			mask = bit.bor(mask, bit.lshift(1, tonumber(x)))
		end

		table.insert(self.checks, {
			name    = name,
			map     = map,
			op      = C.FHKC_U8_MASK64,
			arg     = ffi.new("fhk_arg", {u64=mask}),
			penalty = penalty
		})

		return self
	end
	]]

	error(string.format("syntax error (constraint): %s", def))
end

--------------------------------------------------------------------------------

local testgraph_mt = { __index={} }

local function edgemap(m, edge, groups)
	if edge.map == "" then
		if groups[m.name] ~= groups[edge.name] then
			error(string.format("can't have ident %s(#%d) -> %s(#%d)",
				m.name, groups[m.name].idx, edge.name, groups[edge.name].idx))
		end

		return C.FHK_MAP_IDENT, ffi.new("fhk_arg", {u64=0})
	end

	if edge.map == "@space" then
		return C.FHK_MAP_SPACE, ffi.new("fhk_arg", {u64=0})
	end

	return C.FHK_MAP_USER, ffi.new("fhk_arg", {p=ffi.cast("char *", edge.map)})
end


local function pass(g, fs)
	for _,x in ipairs(g) do
		local f = fs[x[__kind__]]
		if f then f(x) end
	end
end

local function wrapmodel(m)
	local np = #m.params
	local nr = #m.returns
	local f  = m.f

	return function(cm)
		local p = {}
		local e = cm.edges+0

		for i=1, np do
			local ptr = ffi.cast("double *", e.p)
			p[i] = {}
			for j=1, tonumber(e.n) do
				p[i][j] = ptr[j-1]
				--print("->", p[i][j])
			end
			e = e+1
		end

		local r = {f(unpack(p))}

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

local function runsolver(solver, driver)
	while true do
		local status = C.fhk_continue(solver)
		local code = status:code()

		if code == C.FHK_OK then
			return
		end

		if code == C.FHK_ERROR then
			return status:A()
		end

		if code == C.FHKS_SHAPE then
			driver.shape(tonumber(status:X()))
		elseif code == C.FHKS_MAPPING then
			driver.map(ffi.string(status:Xudata().p), ffi.cast("struct fhks_mapping *", status:ABC()))
		elseif code == C.FHKS_MAPPING_INVERSE then
			driver.inverse(ffi.string(status:Xudata().p), ffi.cast("struct fhks_mapping *", status:ABC()))
		elseif code == C.FHKS_COMPUTE_GIVEN then
			driver.given(ffi.string(status:Xudata().p), tonumber(status:A()), tonumber(status:B()))
		elseif code == C.FHKS_COMPUTE_MODEL then
			driver.model(ffi.string(status:Xudata().p), ffi.cast("struct fhks_cmodel *", status:ABC()))
		else
			error(string.format("unhandled status: %d", code))
		end
	end
end

local function driver(models, maps)
	return {
		model = function(name, cmarg)
			models[name](cmarg)
		end,

		map = function(name, mparg)
			mparg.ss[0] = maps[name].map(tonumber(mparg.instance))
		end,

		inverse = function(name, mparg)
			mparg.ss[0] = maps[name].inverse(tonumber(mparg.instance))
		end
	}
end

local function shapetable(groups)
	local st = ffi.new("int16_t[?]", #groups)
	for i,g in ipairs(groups) do
		st[i-1] = g.size
	end
	return st
end

local testgraph_mt = { __index={} }

local function testgraph(g)
	-- [name vm] -> group
	-- [index g] -> group
	local gdefault
	local groups = setmetatable({}, {
		__index = function(self, name)
			if type(name) ~= "string" then
				return
			end

			-- everything that was not explicitly marked goes to a default group (of size 1)
			if not gdefault then
				gdefault = {idx = #self, size = 1}
				table.insert(self, gdefault)
			end

			self[name] = gdefault
			return self[name]
		end
	})

	local maps = {}

	pass(g, {
		group = function(group)
			local g = {
				idx = #groups,
				size = group.size or 1
			}

			table.insert(groups, g)

			for _,name in ipairs(group) do
				groups[name] = g
			end
		end,

		map = function(map)
			maps[map.name] = map
		end
	})

	local def = C.fhk_create_def()
	local dsym = { v = {}, m = {} }

	local vars = setmetatable({}, {
		__index = function(self, name)
			self[name] = C.fhk_def_add_var(def, groups[name].idx, 8,
				ffi.new("fhk_arg", {p=ffi.cast("char *", name)}))
			dsym.v[self[name]] = name
			return self[name]
		end
	})

	local models = {}
	local midx = {}

	pass(g, {
		model = function(m)
			local M = C.fhk_def_add_model(def, groups[m.name].idx, m.k, m.c,
				ffi.new("fhk_arg", {p=ffi.cast("char *", m.name)}))

			midx[m.name] = M
			dsym.m[M] = m.name

			for _,p in ipairs(m.params) do
				C.fhk_def_add_param(def, M, vars[p.name], edgemap(m, p, groups))
			end

			for _,r in ipairs(m.returns) do
				C.fhk_def_add_return(def, M, vars[r.name], edgemap(m, r, groups))
			end

			for _,c in ipairs(m.checks) do
				local map, arg = edgemap(m, c, groups)
				C.fhk_def_add_check(def, M, vars[c.name], map, arg, c.op, c.arg, c.penalty)
			end

			models[m.name] = wrapmodel(m)
		end
	})

	dsym.v = ffi.new("const char *[?]", #dsym.v+1, dsym.v)
	dsym.m = ffi.new("const char *[?]", #dsym.m+1, dsym.m)
	local G = ffi.gc(C.fhk_build_graph(def, nil), function()
		C.free(G)
		dsym = nil
	end)
	C.fhk_set_dsym(G, dsym.v, dsym.m)

	C.fhk_destroy_def(def)

	return setmetatable({
		G       = G,
		st      = shapetable(groups),
		vidx    = setmetatable(vars, nil),
		midx    = midx,
		driver  = driver(models, maps)
	}, testgraph_mt)
end

function testgraph_mt.__index:collectreq(req)
	local creq = ffi.new("struct fhk_req[?]", #req)

	for i,r in ipairs(req) do
		creq[i-1].idx = self.vidx[r.name]
		creq[i-1].ss = r.ss
		creq[i-1].buf = nil
	end

	return creq
end

function testgraph_mt.__index:setshape(solver)
	local status = C.fhkS_shape_table(solver, self.st)
	assert(status:code() == C.FHK_OK)
end

function testgraph_mt.__index:setgiven(solver)
	if self.given_values then
		for name,vals in pairs(self.given_values) do
			local status = C.fhkS_give_all(solver, self.vidx[name], vals)
			assert(status:code() == C.FHK_OK)
		end
	end
end

function testgraph_mt.__index:solve(num, req)
	self.arena = C.arena_create(32000)
	local solver = C.fhk_create_solver(self.G, self.arena, num, req)
	self:setshape(solver)
	self:setgiven(solver)
	local err = runsolver(solver, self.driver)
	return solver, err
end

function testgraph_mt.__index:reduce()
	self.arena = C.arena_create(32000)
	local flags = self.arena:new("uint8_t", self.G.nv)
	ffi.fill(flags, self.G.nv)

	if self.given_names then
		for _, name in ipairs(self.given_names) do
			flags[self.vidx[name]] = C.FHK_GIVEN
		end
	end

	for _, name in ipairs(self.roots) do
		flags[self.vidx[name]] = bit.bor(flags[self.vidx[name]], C.FHK_ROOT)
	end

	return C.fhk_reduce(self.G, self.arena, flags, nil)
end

-- user callbacks

function testgraph_mt.__index:given(vs)
	if #vs > 0 then
		self.given_names = vs
	else
		local given = {}
		for name,val in pairs(vs) do
			if type(val) == "number" then
				val = {val}
			end

			local buf = ffi.new("double[?]", #val)
			for i,v in ipairs(val) do
				buf[i-1] = v
			end

			given[name] = buf
		end

		self.given_values = given
	end
end

function testgraph_mt.__index:root(vs)
	self.roots = vs
end

local function ss(arena, ...)
	local ranges = {...}
	if #ranges == 0 then return 0 end

	if #ranges == 1 then
		local from, to = ranges[1][1], ranges[1][2]
		return bit.lshift(1ULL, 48) + bit.lshift(to, 16) + from
	end

	local rp = ffi.cast("uint32_t *", C.arena_malloc(arena, 4*#ranges))
	for i,r in ipairs(ranges) do
		rp[i-1] = bit.lshift(r[2], 16) + r[1]
	end

	return bit.lshift(ffi.new("uint64_t", #ranges), 48) + ffi.cast("uintptr_t", rp)
end

function testgraph_mt.__index:solution(s)
	local ns = 0
	for _,_ in pairs(s) do ns = ns+1 end

	local req = ffi.new("struct fhk_req[?]", ns)
	local buf = {}
	local i = 0
	for name,val in pairs(s) do
		req[i].idx = self.vidx[name]
		req[i].ss = ss(nil, {0, #val})
		buf[name] = ffi.new("double[?]", #val)
		req[i].buf = buf[name]
		i = i+1
	end

	local solver, err = self:solve(ns, req)

	if err then
		error(string.format("solver was not supposed to fail, but error was: %d", err))
	end

	for name,val in pairs(s) do
		local b = buf[name]
		for i,v in ipairs(val) do
			if v ~= NA and b[i-1] ~= v then
				error(string.format("wrong solution: %s:%d -- got %f, expected %f",
					name, i-1, b[i-1], v))
			end
		end
	end
end

function testgraph_mt.__index:subgraph(names)
	local sub = self:reduce()

	assert(sub ~= ffi.NULL)

	-- names <= sub ?
	for _,name in ipairs(names) do
		if self.vidx[name] then
			if sub.r_vars[self.vidx[name]] == C.FHK_SKIP then
				error(string.format("Variable '%s' not in subgraph", name))
			end
		else
			if sub.r_models[self.midx[name]] == C.FHK_SKIP then
				error(string.format("Model '%s' not in subgraph", name))
			end
		end
	end

	local iv, im = {}, {}
	for _,name in ipairs(names) do
		if self.vidx[name] then iv[self.vidx[name]] = true end
		if self.midx[name] then im[self.midx[name]] = true end
	end

	-- sub <= names?
	for i=0, self.G.nv-1 do
		if sub.r_vars[i] ~= C.FHK_SKIP and not iv[i] then
			error(string.format("Extra variable '%s' in subgraph", ffi.string(self.G.vars[i].udata.p)))
		end
	end

	for i=0, self.G.nm-1 do
		if sub.r_models[i] ~= C.FHK_SKIP and not im[i] then
			error(string.format("Extra model '%s' in subgraph", ffi.string(self.G.models[i].udata.p)))
		end
	end
end

local function inject(env)
	env.m = m
	env.g = g
	env.s = s
	env.NA = NA
	env.graph = function(g)
		local t = testgraph(g)
		env.given = misc.delegate(t, t.given)
		env.root = misc.delegate(t, t.root)
		env.solution = misc.delegate(t, t.solution)
		env.subgraph = misc.delegate(t, t.subgraph)
		env.ss = function(...) return ss(t.arena, ...) end
	end
	return env
end

return function(f)
	return setfenv(f, inject({}))
end
