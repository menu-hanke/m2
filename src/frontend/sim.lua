local ffi = require "ffi"
local C = ffi.C

local errors = {
	[tonumber(C.SIM_EFRAME)]  = "invalid frame",
	[tonumber(C.SIM_ESAVE)]   = "invalid save state",
	[tonumber(C.SIM_EALLOC)]  = "failed to allocate memory",
	[tonumber(C.SIM_EBRANCH)] = "invalid branch point"
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
		branch      = function(self) check(C.sim_branch(self)) end,
		enter_branch= function(self, fp)
			local r = C.sim_enter_branch(self, fp)
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

local function create(opt)
	opt = opt or {}
	local _sim = C.sim_create(
		opt.nframes or 16,
		opt.rsize or 0x1000000
	)

	if _sim == ffi.NULL then
		error("sim: failed to allocate virtual memory")
	end

	ffi.gc(_sim, C.sim_destroy)
	return _sim
end

local function inject(env)
	local sim = env.m2.sim
	env.m2.new = function(ctype, life) return sim:new(ctype, life) end
end

return {
	create = create,
	inject = inject
}
