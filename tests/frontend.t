-- vim: ft=lua
local sim = require "sim"
local sim_env = require "sim_env"

local function with_env(setup)
	return function()
		local sim = sim.create()
		local env = sim_env.create(sim)
		env:inject_base()
		debug.setfenv(setup, env.env)
		local instr, cb = setup()
		sim:compile()
		instr = sim:compile_instr(instr)
		sim:simulate(instr)
		if cb then cb() end
	end
end

test_chain_order = with_env(function()
	local x = 0

	on("event", function()
		assert(x == 1)
		x = x+1
	end)

	on("event#-1", function()
		assert(x == 0)
		x = x+1
	end)

	on("event#1", function()
		assert(x == 2)
	end)

	local instr = record()
	instr.event()
	return instr
end)

test_multi_chain = with_env(function()
	local x = 0

	on("event1", function()
		assert(x % 2 == 0)
		x = x+1
	end)

	on("event2", function()
		assert(x % 2 == 1)
		x = x+1
	end)

	local instr = record()
	for i=1, 10 do
		instr.event1()
		instr.event2()
	end
	return instr
end)

test_chain_arg = with_env(function()
	local x = 0

	on("set", function(v)
		x = v
	end)

	on("check", function(v)
		assert(x == v)
	end)

	local instr = record()
	for i=1, 10 do
		instr.set(i)
		instr.check(i)
	end
	return instr
end)

test_binary_numbers_branching = with_env(function()
	globals.dynamic("bit", "uint32_t")
	globals.dynamic("value", "uint32_t")
	local seen = {}

	local function notset() end
	local function set() G.value = G.value + G.bit end

	local br = branch {
		choice(0x1, notset),
		choice(0x2, set)
	}

	on("firstbit", function()
		G.bit = 1
		G.value = 0
		br()
	end)

	on("nextbit", function()
		G.bit = G.bit * 2
		br()
	end)

	on("leaf", function()
		local x = tonumber(G.value)
		assert(not seen[x])
		seen[x] = true
	end)

	local instr = record()
	instr.firstbit()         -- bit 0
	for i=1, 9 do
		instr.nextbit()      -- bits 1..9
	end
	instr.leaf()             -- record 10 bit number

	return instr, function()
		for i=0, 2^10-1 do
			assert(seen[i])  -- did we see each 10 bit number?
		end
	end
end)

test_branch_continue_chain = with_env(function()
	local seen = {}

	local x
	local function set(v)
		return function() x = v end
	end

	local br = branch {
		choice(0x1, set(1)),
		choice(0x2, set(2)),
		choice(0x3, set(3))
	}

	on("event", function()
		br()
	end)

	on("event#1", function()
		seen[x] = true
	end)

	local instr = record()
	instr.event()

	return instr, function()
		assert(seen[1] and seen[2] and seen[3])
	end
end)

-- TODO: scheduler tests go here
