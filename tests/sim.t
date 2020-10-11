-- vim: ft=lua
local sim = require "sim"
local ffi = require "ffi"
local C = ffi.C

local function _(f)
	return function()
		f(sim.create())
	end
end

test_savepoint = _(function(sim)
	local vsnum = sim:new(ffi.typeof"double", C.SIM_VSTACK)

	vsnum[0] = 1

	sim:savepoint()
	local fp = sim:fp()

	assert(vsnum[0] == 1)
	vsnum[0] = 2

	sim:load(fp)
	assert(vsnum[0] == 1)
	vsnum[0] = 3

	sim:load(fp)
	assert(vsnum[0] == 1)
end)

test_double_savepoint = _(function(sim)
	local v = sim:new(ffi.typeof"double", C.SIM_VSTACK)

	v[0] = 1
	sim:savepoint()
	local fp = sim:fp()

	v[0] = 2
	sim:savepoint()

	v[0] = 3
	sim:load(fp)

	assert(v[0] == 2)

	-- goes back to latest
	sim:load(fp)
	assert(v[0] == 2)
end)

test_leak_savepoint = _(function(sim)
	local v = sim:new(ffi.typeof"double", C.SIM_VSTACK)

	v[0] = 1
	sim:savepoint()
	local fp = sim:fp()

	sim:new(ffi.typeof"double", C.SIM_VSTACK)
	sim:new(ffi.typeof"double", C.SIM_FRAME)

	-- first savepoint is leaked here
	v[0] = 2
	sim:savepoint()

	v[0] = 3
	sim:load(fp)

	assert(v[0] == 2)
end)

test_jump_down = _(function(sim)
	sim:savepoint()
	local fp1 = sim:fp()

	sim:enter()
	sim:savepoint()
	local fp2 = sim:fp()

	sim:load(fp1)
	assert(fails(function() sim:load(fp2) end))
end)

test_tail_branch = _(function(sim)
	sim:branch(C.SIM_CREATE_SAVEPOINT)
	local fid = C.sim_frame_id(sim)
	local fp = sim:fp()

	assert(sim:enter_branch(fp, 0))
	assert(C.sim_frame_id(sim) ~= fid)
	assert(sim:enter_branch(fp, C.SIM_TAILCALL))
	assert(C.sim_frame_id(sim) == fid)
	assert(fails(function() sim:enter_branch(fp, C.SIM_TAILCALL) end))
end)
