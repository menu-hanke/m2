local control = require "control"
local misc = require "misc"
local ffi = require "ffi"
local C = ffi.C

local errors = {
	[tonumber(C.SIM_EFRAME)]  = "Invalid frame",
	[tonumber(C.SIM_ESAVE)]   = "Invalid save state",
	[tonumber(C.SIM_EALLOC)]  = "Failed to allocate memory",
	[tonumber(C.SIM_EBRANCH)] = "Invalid branch point"
}

local function check(r)
	if r > 0 then
		error(errors[r] or string.format("sim error: %d", r))
	end
end

local lifetime = {
	static = C.SIM_STATIC,
	frame  = C.SIM_FRAME,
	vstack = C.SIM_VSTACK
}

local function tolifetime(x)
	return type(x) == "number" and x or lifetime[x]
end

ffi.metatype("sim", {
	__index = {
		enter       = function(self) check(C.sim_enter(self)) end,
		savepoint   = function(self) check(C.sim_savepoint(self)) end,
		restore     = function(self) check(C.sim_restore(self)) end,
		exit        = function(self) check(C.sim_exit(self)) end,
		branch      = function(self, hint) check(C.sim_branch(self, hint)) end,
		take_branch = function(self, id)
			local r = C.sim_take_branch(self, id)
			check(r)
			return r ~= C.SIM_SKIP
		end,

		alloc       = function(self, size, align, life)
			return C.sim_alloc(self, size, align, tolifetime(life))
		end,

		allocator   = function(self, life)
			life = tolifetime(life)
			return function(size, align)
				return C.sim_alloc(self, size, align, life)
			end
		end,

		new         = function(self, ctype, life)
			return ffi.cast(ffi.typeof("$*", ctype),
				C.sim_alloc(self, ffi.sizeof(ctype), ffi.alignof(ctype), tolifetime(life)))
		end
	}
})

local function create()
	local _sim = C.sim_create()

	if _sim == ffi.NULL then
		error("sim: failed to allocate virtual memory")
	end

	ffi.gc(_sim, C.sim_destroy)
	return _sim
end

local function branch(sim, branches)
	-- this is a lazy implementation, it won't even be compiled
	-- TODO: codegen (with same api)
	return function(e, x, s)
		sim:branch(C.SIM_MULTIPLE)

		for id, f in pairs(branches) do
			if sim:take_branch(id) then
				f()
				control.continue(e, x, s)
				sim:exit()
			end
		end
	end
end

local function inject(env)
	env.m2.branch = misc.delegate(env.sim, branch)
	env.m2.new    = misc.delegate(env.sim, env.sim.new)
end

return {
	create = create,
	branch = branch,
	inject = inject
}
