local ffi = require "ffi"
local C = ffi.C

local globals_mt = { __index={} }

local function globalns(sim)
	local ns = {}

	local define = function(name, ctype, static)
		local lifetime = (static and 0) or C.SIM_VSTACK
		local d = C.sim_alloc(sim, ffi.sizeof(ctype), ffi.alignof(ctype), lifetime)
		ns[name] = ffi.cast(ffi.typeof("$*", ctype), d)
	end

	local function check(name)
		local r = ns[name]
		if not r then
			error(string.format("Name '%s' not defined", name))
		end
		return r
	end

	return setmetatable({}, {
		__index = function(_, name)
			return check(name)[0]
		end,

		__newindex = function(_, name, value)
			check(name)[0] = value
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

function globals_mt.__index:define_mappings(solver, define)
	for name,ref in pairs(self.ns) do
		define(name, function()
			local mapping = solver.arena:new("struct fhkM_dataV")
			mapping.flags.resolve = C.FHKM_MAP_DATA
			mapping.ref = ref
			return mapping, true
		end)
	end
end

--------------------------------------------------------------------------------

local function nsdefine(env, define, static)
	local typeof = env.m2.fhk and env.m2.fhk.typeof
	return function(names, ctype)
		names = type(names) == "string" and {names} or names
		if type(ctype) == "table" then ctype = ctype.ctype end
		if type(ctype) == "string" then ctype = ffi.typeof(ctype) end
		for _,name in ipairs(names) do
			define(name, ctype or ffi.typeof(typeof(name).ctype), static)
		end
	end
end

local function inject(env)
	local make_ns = function()
		local ret = globals(env.sim._sim)
		ret.dynamic = nsdefine(env, ret.define, false)
		ret.static = nsdefine(env, ret.define, true)
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
	inject = inject
}
