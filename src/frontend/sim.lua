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
		fp          = function(self) return C.sim_fp(self) end,
		savepoint   = function(self) check(C.sim_savepoint(self)) end,
		load        = function(self, fp) check(C.sim_load(self, fp)) end,
		enter       = function(self) check(C.sim_enter(self)) end,
		branch      = function(self, hint) check(C.sim_branch(self, hint)) end,
		enter_branch= function(self, fp, hint)
			local r = C.sim_enter_branch(self, fp, hint)
			check(r)
			return r ~= C.SIM_SKIP
		end,
		exit_branch = function(self) check(C.sim_exit_branch(self)) end,

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
	return function(continue, x, f)
		sim:branch(C.SIM_CREATE_SAVEPOINT)
		local fp = sim:fp()

		for _, cb in ipairs(branches) do
			if sim:enter_branch(fp, 0) then
				cb()
				f(continue, x)
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
