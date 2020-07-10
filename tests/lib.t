-- vim: ft=lua
local ffi = require "ffi"
local sim = require "sim"
local sim_env = require "sim_env"
local control = require "control"
local fails = fails

local function with_env(setup)
	return function()
		local sim = sim.create()
		local env = sim_env.create(sim)
		env:inject_env()
		env:inject_base()
		debug.setfenv(setup, env.env)
		local instr, cb = setup()
		env:prepare()
		if instr then
			control.exec(env:compile_insn(instr))
			if cb then cb() end
		end
	end
end

test_require_sim_env = with_env(function()
	local f = require "read_sim_env"
	assert(f() == m2)
end)

test_require_hide_path = with_env(function()
	assert(fails(function() require "sim_env" end))
end)

test_chain_order = with_env(function()
	local x = 0

	m2.on("event", function()
		assert(x == 1)
		x = x+1
	end)

	m2.on("event#-1", function()
		assert(x == 0)
		x = x+1
	end)

	m2.on("event#1", function()
		assert(x == 2)
	end)

	local instr = m2.record()
	instr.event()
	return instr
end)

test_multi_chain = with_env(function()
	local x = 0

	m2.on("event1", function()
		assert(x % 2 == 0)
		x = x+1
	end)

	m2.on("event2", function()
		assert(x % 2 == 1)
		x = x+1
	end)

	local instr = m2.record()
	for i=1, 10 do
		instr.event1()
		instr.event2()
	end
	return instr
end)

test_chain_arg = with_env(function()
	local x = 0

	m2.on("set", function(v)
		x = v
	end)

	m2.on("check", function(v)
		assert(x == v)
	end)

	local instr = m2.record()
	for i=1, 10 do
		instr.set(i)
		instr.check(i)
	end
	return instr
end)

test_binary_numbers_branching = with_env(function()
	local G = m2.new(ffi.typeof [[
		struct {
			uint32_t bit;
			uint32_t value;
		}
	]], "vstack")

	local seen = {}

	local function notset() end
	local function set() G.value = G.value + G.bit end

	local branch = m2.branch { notset, set }

	m2.on("firstbit", function()
		G.bit = 1
		G.value = 0
		return branch
	end)

	m2.on("nextbit", function()
		G.bit = G.bit * 2
		return branch
	end)

	m2.on("leaf", function()
		local x = tonumber(G.value)
		assert(not seen[x])
		seen[x] = true
	end)

	local instr = m2.record()
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

	local branch = m2.branch { set(1), set(2), set(3) }

	m2.on("event", function()
		return branch
	end)

	m2.on("event#1", function()
		seen[x] = true
	end)

	local instr = m2.record()
	instr.event()

	return instr, function()
		assert(seen[1] and seen[2] and seen[3])
	end
end)

-- TODO: nämä erikseen vmath.t

test_vmath_kernel_reduce = with_env(function()
	local sum = m2.vmath.loop(1, true):reduce(function(a, b) return a+b end, 0)
	local v = m2.allocv(3)
	v.data[0] = 1; v.data[1] = 2; v.data[2] = 3

	assert(sum(v) == 1+2+3)
end)

test_vmath_kernel_raw = with_env(function()
	local sqsum = m2.vmath.loop(1):map(function(x) return x^2 end):sum()
	local v = m2.allocv(3)
	v.data[0] = 1; v.data[1] = 2; v.data[2] = 3

	assert(sqsum(v.data, #v) == 1^2+2^2+3^2)
end)

test_vmath_kernel_multiple = with_env(function()
	local dot = m2.vmath.loop(2, true):map(function(x, y) return x*y end):sum()
	local x, y = m2.allocv(3), m2.allocv(3)
	x.data[0] = 1; x.data[1] = 2; x.data[2] = 3
	y.data[0] = 4; y.data[1] = 5; y.data[2] = 6

	assert(dot(x, y) == 1*4+2*5+3*6)
end)

-- TODO: vec testit
-- TODO: scheduler tests go here
