local alloc = require "alloc"
local cli = require "cli"
local misc = require "misc"
local soa = require "soa"
local ctypes = require "fhk.ctypes"
local def = require "fhk.def"
local plan = require "fhk.plan"
local mapping = require "fhk.mapping"
local ffi = require "ffi"

---- test runner ----------------------------------------

local testgroup_mt = { __index={} }
local testsolver_mt = { __index={} }
local testbuilder_mt = { __index={} }

local function testbuilder(check)
	return setmetatable({
		check      = check,
		solvers    = {},
		groups     = {},
		auto_edges = {}
	}, testbuilder_mt)
end

local function testgroup()
	return setmetatable({}, testgroup_mt)
end

local function testsolver()
	return setmetatable({}, testsolver_mt)
end

function testbuilder_mt.__index:add_given(name, ctype)
	local group = mapping.groupof(name)
	if not self.groups[group] then
		self.groups[group] = testgroup()
	end

	self.groups[group]:add(name, ctype)
end

function testbuilder_mt.__index:add_solver(name, outputs)
	local solver = testsolver()

	for _,name in ipairs(outputs) do
		solver:add(name)
	end

	self.solvers[name] = solver
end

function testbuilder_mt.__index:automap_given(given)
	for name,ctype in pairs(given) do
		self:add_given(name, ctype)
	end
end

function testbuilder_mt.__index:automap_edges(edges)
	for _,rule in ipairs(edges) do
		table.insert(self.auto_edges, { rule[1], mapping.builtin_maps[rule[2]] })
	end
end

function testbuilder_mt.__index:from_def(graph)
	if graph.given then
		for name,ctype in pairs(graph.given) do
			self:add_given(name, ctype)
		end
	end

	if graph.map_edges then
		self:automap_edges(graph.map_edges)
	end

	if graph.solvers then
		for name,outputs in pairs(graph.solvers) do
			self:add_solver(name, outputs)
		end
	end

	return self
end

function testbuilder_mt.__index:runner(G)
	if #self.auto_edges > 0 then
		G:edge(mapping.match_edges(self.auto_edges))
	end

	local updaters = {}

	for name,group in pairs(self.groups) do
		local mapper, update = group:mapping()
		G:given(mapping.parallel_group(name, mapper))
		table.insert(updaters, update)
	end

	local solvers = {}

	for name,solver in pairs(self.solvers) do
		solvers[name] = solver:runner(G, self.check)
	end

	return function(case)
		for _,u in ipairs(updaters) do
			u(case.data)
		end

		local errors

		for _,s in ipairs(case.solvers) do
			local err = solvers[s](case.data, {})
			if err then
				errors = errors or {}
				table.insert(errors, {
					string.format("solver: %s", s),
					err
				})
			end
		end

		return errors
	end
end

function testgroup_mt.__index:add(name, ctype)
	table.insert(self, {
		name  = name,
		ctype = ctype,
		field = string.format("_%d", #self)
	})
end

function testgroup_mt.__index:mapping()
	local bands, translate = {}, {}
	for _,var in ipairs(self) do
		bands[var.field] = var.ctype

		-- XXX: this match is to get the name without the group prefix (group#name),
		-- because the parallel_group tries to map without group prefix.
		-- it might be cleaner to make parallel_group not translate by default?
		translate[var.name:match("^.-#(.+)$")] = var.field
	end

	local ctype = soa.ctfrombands(bands)
	local instance = ctype()

	local mapper = mapping.translate_mapper(translate, mapping.soa_mapper(ctype, instance))

	-- XXX: buffers allocated with `ffi.new` must be anchored in a lua object to prevent gc
	local _anchor = {}

	return mapper, function(data)
		local n = #data[self[1].name]

		if n > ffi.cast("struct vec *", instance).n_alloc then
			for _,var in ipairs(self) do
				local value = ffi.new(ffi.typeof("$[?]", ffi.typeof(var.ctype)), n)
				instance[var.field] = value
				-- note: this assignment must be from the cdata, if it's assigned to instance
				-- and then read back, it will create a new cdata (pointer) and the backing allocation
				-- will be gced.
				_anchor[var.field] = value
			end
			ffi.cast("struct vec *", instance).n_alloc = n
		end

		ffi.cast("struct vec *", instance).n_used = n

		for _,var in ipairs(self) do
			local vec = data[var.name]
			if #vec ~= n then
				error(string.format("inconsistent group shape: len(%s)=%d but len(%s)=%d",
					self[1].name, n, var.name, #vec))
			end

			local buf = instance[var.field]
			for i=1, n do
				buf[i-1] = vec[i]
			end
		end
	end
end

function testsolver_mt.__index:add(name)
	table.insert(self, {
		name   = name,
		alias  = string.format("_v_%d", #self),
		subset = string.format("_ss_%d", #self)
	})
end

local function checkv_eps(buf, values, eps)
	eps = eps or 0.001

	local errors
	local idx = 0
	for i=1, #values do
		if type(values[i]) == "number" then
			if math.abs(buf[idx] - values[i]) > eps then
				errors = errors or {}
				table.insert(errors, string.format("[%d]: %f != %f", i-1, buf[idx], values[i]))
			end
			idx = idx+1
		end
	end

	return errors
end

function testsolver_mt.__index:runner(G, check)
	local solver = G:solver()

	for _,var in ipairs(self) do
		solver:solve(var.name, var)
	end

	solver = solver:create()

	return function(data, params)
		params._solver_anchor = {}

		for _,var in ipairs(self) do
			local ss = ctypes.ss_builder()

			for i,v in ipairs(data[var.name]) do
				if type(v) == "number" then
					ss:add(i-1)
				end
			end

			local subset, _ref = ss:to_subset()
			table.insert(params._solver_anchor, _ref)
			params[var.subset] = subset
		end

		local ok, result = pcall(solver, params)
		if not ok then
			return {
				"solver failed",
				result
			}
		end

		local errors

		for _,var in ipairs(self) do
			local err = check(result[var.alias], data[var.name])
			if err then
				errors = errors or {}
				table.insert(errors, {
					string.format("variable: %s", var.name),
					err
				})
			end
		end

		return errors
	end
end

local function _flatten_errors(errors, f)
	for _,e in ipairs(errors) do
		if type(e) == "table" then
			_flatten_errors(e, function(x)
				f("\t" .. x)
			end)
		else
			f(tostring(e))
		end
	end
end

local function stringify_errors(errors)
	local out = {}

	_flatten_errors(errors, function(x)
		table.insert(out, x)
	end)

	return table.concat(out, "\n")
end

---- debugging session ----------------------------------------

local session_f = {}
local session_def_mt = { __index=setmetatable({}, {__index=session_f}) }
local session_g_mt = { __index=setmetatable({}, {__index=session_f}) }

local function session(debugger)
	local gdef = def.create()

	local ses = setmetatable({
		debugger        = debugger,
		plan            = plan.create(),
		def             = gdef,
		def_env         = def.env(gdef),
		_finalize_hooks = {},
	}, session_def_mt)

	ses.env = setmetatable({}, {
		__index = function(_, name)
			if ses[name] then
				if type(ses[name]) == "function" then
					return misc.delegate(ses, ses[name])
				else
					return ses[name]
				end
			end

			return _G[name]
		end
	})

	return ses
end

function session_f:exec(fname)
	local f, err = loadfile(fname, nil, self.env)
	if err then
		error(err)
	end

	f()
end

function session_f:exec_string(s)
	local f, err = load(s)
	if err then
		error(err)
	end

	setfenv(f, self.env)()
end

function session_def_mt.__index:read(fname)
	self.def_env.read(fname)
end

function session_def_mt.__index:on_finalize(f)
	table.insert(self._finalize_hooks, f)
end

function session_def_mt.__index:subgraph(...)
	return self.plan:subgraph(...)
end

function session_def_mt.__index:finalize()
	setmetatable(self, session_g_mt)

	self.plan:finalize(self.def, {
		static_alloc = self.debugger.static_alloc,
		runtime_alloc = self.debugger.runtime_alloc
	})

	for _,f in ipairs(self._finalize_hooks) do
		self.debugger.runtime_arena:reset()
		f()
	end
end

local debugger_mt = { __index={ session = session } }

local function debugger()
	local static_arena = alloc.arena()
	local runtime_arena = alloc.arena()

	return setmetatable({
		static_arena = static_arena,
		runtime_arena = runtime_arena,
		static_alloc = misc.delegate(static_arena, static_arena.alloc),
		runtime_alloc = misc.delegate(runtime_arena, runtime_arena.alloc)
	}, debugger_mt)
end

--------------------------------------------------------------------------------

local function main(args)
	local debugger = debugger()
	local session = debugger:session()

	if args.graph then
		for _,gfile in ipairs(args.graph) do
			session:read(gfile)
		end
	end

	if args.files then
		for _,xfile in ipairs(args.files) do
			session:exec(xfile)
		end
	end

	local testers
	if args.tests then
		local eps = tonumber(args.epsilon) or 0.01
		local check = function(a, b) return checkv_eps(a, b, eps) end 

		local cjson = require "cjson"
		testers = {}
		for _,t in ipairs(args.tests) do
			local def = cjson.decode(io.open(t):read("*a"))
			table.insert(testers, {
				runner = testbuilder(check):from_def(def.graph):runner(session.plan:subgraph()),
				cases  = def.testcases,
				name   = t
			})
		end
	end

	session:finalize()

	if args.tests then
		for _,test in ipairs(testers) do
			for i,case in ipairs(test.cases) do
				debugger.runtime_arena:reset()
				local errors = test.runner(case)
				if errors then
					cli.print("%s %s :: %s\n%s", cli.red "[FAIL]", test.name, i,
						stringify_errors(errors))
				else
					cli.verbose("%s %s :: %d", cli.green "[OK]", test.name, i)
				end
			end
		end
	end
end

local flags, help = cli.def(function(opt)
	opt { "-g", "graph", multiple=true, help="graph file" }
	opt { "-e", "commands", multiple=true, help="execute a debugger command" }
	opt { "-x", "files", multiple=true, help="execute debugger commands from a file" }
	opt { "-t", "tests", multiple=true, help="test graph output" }
	opt { "-E", "epsilon", help="max error (default: 0.01)"}
end)

return {
	cli = {
		main = main,
		help = "[options]...\n\n"..help,
		flags = flags
	}
}
