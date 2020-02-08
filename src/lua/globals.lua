local ffi = require "ffi"
local typing = require "typing"
local fhk = require "fhk"
local C = ffi.C

local globals_mt = { __index={} }

local function globalns(sim)
	local ns = {}

	local define = function(name, ctype, static)
		local lifetime = (static and 0) or C.SIM_VSTACK
		local d = C.sim_alloc(sim, ffi.sizeof(ctype), ffi.alignof(ctype), lifetime)
		ns[name] = ffi.cast(ctype .. "*", d)
	end

	return setmetatable({}, {
		__index = function(_, name)
			return ns[name][0]
		end,

		__newindex = function(_, name, value)
			ns[name][0] = value
		end
	}), define, ns
end

local function globals(sim)
	local G, define, ns = globalns(sim)
	return setmetatable({
		sim = sim,
		G = G,
		define = define,
		ns = ns
	}, globals_mt)
end

function globals_mt.__index:is_constant()
	return true
end

function globals_mt.__index:mark_mappings(_, mark)
	for name,_ in pairs(self.ns) do
		mark(name)
	end
end

function globals_mt.__index:map_var(solver, v)
	return solver.mapper:data(v.name, self.ns[v.name])
end

--------------------------------------------------------------------------------

local function nsdefine(m2, define, static)
	return function(names, ctype)
		names = type(names) == "string" and {names} or names
		ctype = type(ctype) == "string" and ctype or (ctype and ctype.ctype)
		for _,name in ipairs(names) do
			define(name, ctype or m2.fhk.typeof(name).ctype, static)
		end
	end
end

local function inject(env)
	local make_ns = function()
		local ret = globals(env.sim._sim)
		ret.dynamic = nsdefine(env.m2, ret.define, false)
		ret.static = nsdefine(env.m2, ret.define, true)
		return ret, ret.G
	end

	env.m2.ns = setmetatable({
		dynamic = function(names, ctype)
			local ret, G = make_ns()
			ret.dynamic(names, ctype)
			return ret, G
		end,
		static = function(names, ctype)
			local ret, G = make_ns()
			ret.static(names, ctype)
			return ret, G
		end
	}, { __call = make_ns })
end

return {
	inject         = inject,
	create_solver1 = create_solver1
}
