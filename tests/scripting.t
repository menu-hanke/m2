-- vim: ft=lua
local sim = require "sim"
local scripting = require "scripting"
local fails = fails

local function _(f)
	return function()
		local env = scripting.env(sim.create())
		setfenv(f, env)()
	end
end

test_sandbox_sim_env = _(function()
	local f = require "read_sim_env"
	assert(f() == m2)
end)

test_sandbox_hide_path = _(function()
	assert(fails(function() require "scripting" end))
end)

test_hook = _(function()
	local env = scripting.env(sim.create())
	local called = false

	setfenv(function()
		m2.library {
			myhook = function()
				called = true
			end
		}
	end, env)()

	scripting.hook(env, "myhook")
	assert(called)
end)
