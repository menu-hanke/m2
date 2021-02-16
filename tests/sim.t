-- vim: ft=lua
local sim = require "sim"
local ffi = require "ffi"

test_savepoint = function()
	local sim = sim.create()
	local vsnum = sim:new(ffi.typeof"double", "vstack")

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
end

test_double_savepoint = function()
	local sim = sim.create()
	sim:savepoint()
	assert(fails(function() sim:savepoint() end, "invalid save state"))
end

test_double_branch = function()
	local sim = sim.create()
	sim:branch()
	assert(fails(function() sim:branch() end, "invalid branch point"))
end

test_oom_new = function()
	local sim = sim.create({ rsize=2^8 })
	assert(sim:new(ffi.typeof "uint8_t[1024]", "vstack") == nil)
end

test_oom_savepoint = function()
	local sim = sim.create({ rsize=2^8 })
	sim:new(ffi.typeof "uint8_t[129]", "vstack")
	sim:new(ffi.typeof "uint8_t[129]", "frame")
	assert(fails(function() sim:savepoint() end, "failed to allocate memory"))
end

test_invalid_frame_jump = function()
	local sim = sim.create()
	assert(ffi.C.sim_up(sim, 2) == ffi.C.SIM_EFRAME)
end

test_invalid_savepoint = function()
	local sim = sim.create()
	assert(fails(function() sim:reload() end), "invalid save state")
end

test_invalid_frame_savepoint = function()
	local sim = sim.create()
	sim:savepoint()
	sim:enter()
	assert(fails(function() sim:reload() end), "invalid save state")
end

test_oof = function()
	local sim = sim.create({ nframes=2 })
	sim:enter()
	assert(fails(function() sim:enter() end), "invalid frame")
end

test_invalid_branchpoint = function()
	local sim = sim.create()
	-- this could fail either due to a missing savepoint or missing branchpoint,
	-- so the message isn't checked
	assert(fails(function() sim:enter_branch(sim:fp()) end))
end
