-- vim: ft=lua
local sim = require "sim"
local memoize = require "memoize"
local scripting = require "scripting"
local ffi = require "ffi"

test_memoize_savepoint = function()
	local sim = sim.create()
	local num = sim:new(ffi.typeof "double", "vstack")
	local neval = 0

	local function square(x)
		neval = neval + 1
		return x^2
	end

	local sq = memoize.memoize(sim, square, 1, 1)

	-- should only evaluate once
	assert(sq(3) == 9)
	assert(sq(3) == 9)
	assert(neval == 1)

	local fp = sim:fp()
	sim:savepoint()
	sim:enter()

	-- don't reevaluate after savepoint change
	sq(3)
	assert(neval == 1)

	-- do reevaluate for new value
	assert(sq(4) == 16)
	assert(neval == 2)

	-- but remember saved value on old frame
	sim:load(fp)
	assert(sq(3) == 9)
	assert(neval == 2)

	-- but don't remember stale value from exited frame
	sim:enter()
	assert(sq(4) == 16)
	assert(neval == 3)
end

test_memoize_multiple = function()
	local sim = sim.create()
	local f = memoize.memoize(sim, function(a, b)
		return a+b, a-b
	end, 2, 2)

	local x, y = f(1, 2)
	assert(x == 1+2 and y == 1-2)
end

test_inject_memoize = function()
	local env = scripting.env(sim.create())
	memoize.inject(env)

	setfenv(function()
		local sum = m2.memoize(function(a, b)
			return a+b
		end)
		assert(sum(1, 2) == 3)
	end, env)()
end
