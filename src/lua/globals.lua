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

function globals_mt.__index:expose(mapper)
	for name,p in pairs(self.ns) do
		if mapper.vars[name] then
			fhk.support.global(mapper:data(name, p))
		end
	end
end

function globals_mt.__index:mark_visible(mapper, G, vmask)
	G:mark_visible(vmask, C.GMAP_BIND_GLOBAL, typing.tvalue.u64(0))
end

function globals_mt.__index:mark_nonconstant(mapper, G, vmask)
	G:mark_nonconstant(vmask, C.GMAP_BIND_GLOBAL, typing.tvalue.u64(0))
end

function globals_mt.__index:solver_func(mapper, solver)
	local values = ffi.cast("pvalue *", C.sim_static_alloc(self.sim,
		solver.nv * ffi.sizeof("pvalue"), ffi.alignof("pvalue")))
	
	for i=0, tonumber(solver.nv)-1 do
		solver:bind(i, values+i)
	end

	return function()
		return (C.gs_solve_step(solver, 0))
	end
end

function globals_mt.__index:virtualize(mapper, name, f)
	fhk.support.global(mapper:virtual(name, f))
end

--------------------------------------------------------------------------------

local function get_ctype(name, ctype, env)
	if type(ctype) == "string" then return ctype end
	if ctype and ctype.ctype then return ctype.ctype end
	return env.fhk.typeof(name).ctype
end

local function globalsfunc(m2, static)
	return function(names, ctype)
		names = type(names) == "string" and {names} or names
		ctype = type(ctype) == "string" and ctype or (ctype and ctype.ctype)
		for _,name in ipairs(names) do
			m2.globals.define(name, ctype or m2.fhk.typeof(name).ctype, static)
		end
	end
end

local function inject(env)
	local gs = globals(env.sim._sim)
	gs.dynamic = globalsfunc(env.m2, false)
	gs.static = globalsfunc(env.m2, true)

	env.m2.globals = gs
	env.m2.G = gs.G
end

return {
	inject = inject
}
