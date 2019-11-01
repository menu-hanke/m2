-- vim: ft=lua
local ffi = require "ffi"
local sim = require "sim"
local sim_env = require "sim_env"
local bt = require "buildtype"

local function with_env(setup)
	return function()
		local sim = sim.create()
		local env = sim_env.create(sim)
		env:inject_base()
		debug.setfenv(setup, env.env)
		local instr, cb = setup()
		sim:compile()
		if instr then
			instr = sim:compile_instr(instr)
			sim:simulate(instr)
			if cb then cb() end
		end
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

test_vec_codegen = with_env(function()
	local V = obj(component(bt.builtins {
		f32 = "real32",
		f64 = "real64",
		b8  = "bit8",
		b16 = "bit16",
		b32 = "bit32",
		b64 = "bit64",
		p   = "udata"
	}))

	local vec = V:vec()
	vec:alloc(1)

	local cvec = vec:cvec()

	-- is layout same as struct vec?
	assert(vec:len() == cvec.n_used)
	assert(vec:alloc_len() == cvec.n_alloc)

	local cinfo = vec:cinfo()

	-- verify it created the struct we described above
	assert(cinfo.n_bands == 7)

	-- bands will be in arbitrary order, but the strides should match:
	--   1x 1 byte (b8)
	--   1x 2 byte (b16)
	--   2x 4 byte (f32, b32)
	--   2x 8 byte (f64, b64)
	--   1x pointer length (4 or 8)
	local stride = {
		[1] = 1,
		[2] = 1,
		[4] = 2,
		[8] = 2
	}
	local psize = tonumber(ffi.sizeof("void *"))
	stride[psize] = stride[psize] + 1

	for i=0, tonumber(cinfo.n_bands)-1 do
		local s = cinfo.stride[i]
		assert(stride[s] > 0)
		stride[s] = stride[s] - 1
	end
end)

test_vec_lazy = with_env(function()
	local comp = component(bt.reals("x", "y"))

	comp:lazy("y", function(band, vs)
		vs:bandv("x"):add(100, band)
	end)

	local V = obj(comp)
	local v = V:vec()

	v:alloc(4)
	local x = v:newband("x")
	x[0] = 1
	x[1] = 2
	x[2] = 7
	x[3] = 3

	assert(v:band("y") == ffi.NULL)

	local y = V:realize(v, "y")
	assert(y[0] == 101 and y[1] == 102 and y[2] == 107 and y[3] == 103)

	-- shouldn't be recomputed
	x[0] = 0
	assert(V:realize(v, "y") == y)
	assert(y[0] == 101)

	-- should be cleared
	V:unrealize(v)
	y = V:realize(v, "y")
	assert(y[0] == 100)

	-- this should also recompute
	V:alloc(v, 1):band("x")[0] = 123
	y = V:realize(v, "y")
	assert(y[0] == 100 and y[1] == 102 and y[2] == 107 and y[3] == 103 and y[4] == 223)
end)

-- TODO: scheduler tests go here
