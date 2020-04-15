-- vim: ft=lua
local calibrate = require "calibrate"
local sim = require "sim"
local sim_env = require "sim_env"
local misc = require "misc"
local T = require "testgraph"

local epsilon = 0.1

local function t(f)
	return function()
		math.randomseed(0x123456789)

		local sim = sim.create()
		local env = sim_env.create(sim)
		env:inject_base()

		local costf, coef, solution
		env.env.cost = function(c) costf = c end
		env.env.coef = function(c) coef = c end
		env.env.solution = function(sol) solution = sol end

		local testenv = T.injector(misc.delegate(env, env.inject_fhk))
		testenv(env.env)
		setfenv(f, env.env)

		f()

		local calibrator = calibrate.calibrator(env, coef)
		sim:compile()

		local s = calibrator:optimize({costf=costf})
		for model,coef in pairs(solution) do
			local ss = s[model]
			for name,v in pairs(coef) do
				if math.abs(ss[name] - v) > epsilon then
					error(string.format("%s: expected %s=%s but solution is %s",
					model, name, v, ss[name]))
				end
			end
		end
	end
end

test_optimize = t(function()
	graph {
		m("->x,y", "Lua::models::id"):coef{"c0", "c1"},
		h{x="real", y="real"}
	}

	coef {
		["->x,y"] = {
			c0 = {
				value    = 100,
				min      = -1000,
				max      = 1000,
				optimize = true
			},

			c1 = {
				value    = -100,
				min      = -1000,
				max      = 1000,
				optimize = true
			}
		}
	}

	local solver = m2.fhk.solve("x", "y")

	cost(function()
		solver()
		return (10 - solver.x)^2 + (10 + solver.y)^2
	end)

	solution {
		["->x,y"] = {
			c0 = 10,
			c1 = -10
		}
	}
end)

test_uncalibrated_parameter = t(function()
	graph {
		m("->x,y", "Lua::models::id"):coef{"c0", "c1"},
		m("->z,w", "Lua::models::id"):coef{"c0", "c1"},
		h{x="real", y="real", z="real", w="real"}
	}

	coef {
		["->x,y"] = {
			c0 = {
				value    = 0,
				min      = -10,
				max      = 10,
				optimize = true
			},

			c1 = {
				value    = 0
			}
		},

		["->z,w"] = {
			c0 = {
				value    = 0
			},

			c1 = {
				value    = 0,
				min      = -10,
				max      = 10,
				optimize = true
			}
		}
	}

	local solver = m2.fhk.solve("x", "y", "z", "w")

	cost(function()
		solver()
		return (1 - solver.x)^2 + (2 - solver.y)^2 + (3 - solver.z)^2 + (4 - solver.w)^2
	end)

	solution {
		["->x,y"] = {
			c0 = 1
		},
		["->z,w"] = {
			c1 = 4
		}
	}
end)
