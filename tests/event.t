-- vim: ft=lua
local sim = require "sim"
local sim_env = require "sim_env"
local events = require "event"
local testev = require "testev"
local fails = fails

local function _(f)
	return function()
		local env = sim_env.create(sim.create())
		env:inject_base()

		local def = events.def()
		events.inject(env, def)

		local td = testev.test_def(env.m2)
		local evenv = events.env(def)
		td:inject(evenv)

		setfenv(f, evenv)(function(g) setfenv(g, env.env)() end)
		td:assert_hypothesis(env)
	end
end

---> a --->
test_forced = _(function()
	event "test" {
		forced,
		operation.call("a")
	}

	steps { 0 }

	paths {
		a = 1
	}
end)

---> a/_  ---> b/_ --->
test_combined_branch = _(function()
	event "a" {
		operation.call("a")
	}

	event "b" {
		operation.call("b")
	}

	steps { 0 }

	paths {
		_ = 1,
		a = 1,
		b = 1,
		ab = 1
	}
end)

---> a/b/_ --->
test_blocked_branch = _(function()
	event "a" {
		blocked_by ".*",
		operation.call("a")
	}

	event "b" {
		blocked_by ".*",
		operation.call("b")
	}

	steps { 0 }

	paths {
		_ = 1,
		a = 1,
		b = 1
	}
end)

---> a ---> b/_ ---> c --->
test_forced_interleaved_branch = _(function()
	event "a" {
		forced,
		operation.call("a")
	}

	event "b" {
		after "a",
		operation.call("b")
	}

	event "c" {
		forced,
		after "b",
		operation.call("c")
	}

	steps { 0 }

	paths {
		ac  = 1,
		abc = 1
	}
end)

---> * ---> a ---> c --->
--    \---> b ---------->
--    \---> _ ---------->
test_require = _(function()
	event "a" {
		blocked_by "b",
		operation.call("a")
	}

	event "b" {
		blocked_by "a",
		operation.call("b")
	}

	event "c" {
		forced,
		requires "a",
		operation.call("c")
	}

	steps { 0 }

	paths {
		ac = 1,
		b  = 1,
		_  = 1
	}
end)

---> a/b/_ --->
test_rule = _(function()
	rule ".*" {
		blocked_by ".*"
	}

	event "a" {
		operation.call("a")
	}

	event "b" {
		operation.call("b")
	}

	steps { 0 }

	paths {
		a = 1,
		b = 1,
		_ = 1
	}
end)

---> b ---> a --->
test_temporal_order = _(function()
	event "a" {
		forced,
		operation.call("a")
	}

	event "b" {
		forced,
		before "a",
		operation.call("b")
	}

	steps { 0 }

	paths {
		ba = 1
	}
end)

---> b ---> a --->
test_require_order = _(function()
	event "a" {
		forced,
		requires "b",
		operation.call("a")
	}

	event "b" {
		forced,
		operation.call("b")
	}

	steps { 0 }

	paths {
		ba = 1
	}
end)

---> a# ///> b
test_fail_require = _(function()
	event "a" {
		forced,
		operation.always_fails()
	}

	event "b" {
		forced,
		requires "a",
		operation.call("b")
	}

	steps { 0 }

	paths {}
end)

---> * ---> a# ///> c
--    \---> b  ---> c
--    \---> _  ---> c
test_cancel_branch = _(function()
	event "1:a" {
		blocked_by "1:.*",
		operation.always_fails()
	}

	event "1:b" {
		blocked_by "1:.*",
		operation.call("b")
	}

	event "c" {
		forced,
		after "1:.*",
		operation.call("c")
	}

	steps { 0 }

	paths {
		bc = 1,
		c  = 1
	}
end)

---> * ---> a ---> b ----------------->
--    \----------> b ---> * ---> c --->
--                        \ ---------->
test_unliftable_branch = _(function()
	event "1:a" {
		blocked_by "1:.*",
		operation.call("a")
	}

	event "b" {
		after "1:a",
		forced,
		operation.call("b")
	}

	event "1:c" {
		after "b",
		blocked_by "1:.*",
		operation.call("c")
	}

	steps { 0 }

	paths {
		ab = 1,
		bc = 1,
		b  = 1
	}
end)

---> * ---> a ----------------->
--   \ ---> b ---> * ---> c --->
--                  \---> _ --->
--   \ ---> _ ---> * ---> c --->
--                  \---> _ --->
test_partial_block = _(function()
	event "a" {
		blocked_by { "a", "b" },
		operation.call("a")
	}

	event "b" {
		blocked_by { "a", "b" },
		operation.call("b")
	}

	event "c" {
		after { "a", "b" },
		blocked_by { "a", ",c" },
		operation.call("c")
	}

	steps { 0 }

	paths {
		a  = 1,
		bc = 1,
		b  = 1,
		c  = 1,
		_  = 1
	}
end)

--   0          1
---> a/b/_ ---> a/b/_ --->
test_multistep_branch = _(function()
	event "a" {
		blocked_by ".*",
		operation.call("a")
	}

	event "b" {
		blocked_by ".*",
		operation.call("b")
	}

	steps { 0, 1 }

	paths {
		aa = 1,
		ab = 1,
		a  = 2,
		ba = 1,
		bb = 1,
		b  = 2,
		_  = 1
	}
end)

test_temporal_cycle = _(function()
	event "a" {
		before "b",
		operation.call("a")
	}

	event "b" {
		before "a",
		operation.call("b")
	}

	compile_fails()
end)

test_require_cycle = _(function()
	event "a" {
		requires "b",
		operation.call("a")
	}

	event "b" {
		requires "a",
		operation.call("b")
	}

	compile_fails()
end)

test_mixed_cycle = _(function()
	event "a" {
		after "b",
		operation.call("a")
	}

	event "b" {
		requires "a",
		operation.call("b")
	}

	compile_fails()
end)

-- 0      1              2
-- a ---> (blocked) ---> a --->
test_block_time = _(function()
	event "a" {
		forced,
		blocked_time(2),
		blocked_by "a",
		operation.call("a")
	}

	steps { 0, 1, 2 }

	paths {
		aa = 1
	}
end)

-- 0             1
--                /---> _
-- * ---> a ---> * ---> b
--  \---> b ---> * ---> b
--  \---> _       \---> _
--         \---> * ---> a
--                \---> b
--                \---> _
test_nonequal_block_time_branch = _(function()
	event "a" {
		blocked_by ".*",
		blocked_time(2),
		operation.call("a")
	}

	event "b" {
		blocked_by ".*",
		blocked_time(0.5),
		operation.call("b")
	}

	steps { 0, 1 }

	paths {
		a  = 2,
		ab = 1,
		bb = 1,
		b  = 2,
		_  = 1
	}
end)

-- TODO: semi-forced branches
