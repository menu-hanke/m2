-- vim: ft=lua
local ffi = require "ffi"
local C = ffi.C

local function with_sim(f)
	return function()
		local sim = C.sim_create()
		f(sim)
		C.sim_destroy(sim)
	end
end

local function new(sim, ct, lt)
	ct = type(ct) == "string" and ffi.typeof(ct) or ct
	local rt = ffi.typeof("$ *", ct)
	return ffi.cast(rt, C.sim_alloc(sim, ffi.sizeof(ct), ffi.alignof(ct), lt))
end

test_single_branch = with_sim(function(sim)
	local fid = C.sim_frame_id(sim)
	C.sim_branch(sim, 0)
	assert(C.sim_take_branch(sim, 0) == C.SIM_OK)
	assert(C.sim_frame_id(sim) ~= fid)
	C.sim_exit(sim)
	assert(C.sim_frame_id(sim) == fid)
end)

test_savepoint = with_sim(function(sim)
	local vsnum = new(sim, "double", C.SIM_VSTACK)

	vsnum[0] = 1

	C.sim_enter(sim)
	C.sim_savepoint(sim)

	assert(vsnum[0] == 1)
	vsnum[0] = 2

	C.sim_restore(sim)
	assert(vsnum[0] == 1)
	vsnum[0] = 3

	C.sim_restore(sim)
	assert(vsnum[0] == 1)

	C.sim_exit(sim)
	assert(vsnum[0] == 1)
end)

test_branch_save = with_sim(function(sim)
	local vsnum = new(sim, "double", C.SIM_VSTACK)

	vsnum[0] = 1

	C.sim_branch(sim, C.SIM_MULTIPLE);
	for i=1, 3 do
		assert(C.sim_take_branch(sim, i) == C.SIM_OK)
		assert(vsnum[0] == 1)
		vsnum[0] = 100+i
		C.sim_exit(sim)
	end
end)
