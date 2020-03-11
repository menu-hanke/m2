-- vim: ft=lua
local ffi = require "ffi"
local sim = require "sim"
local sim_env = require "sim_env"
local bt = require "buildtype"
local fails = fails

local function with_env(setup)
	return function()
		local sim = sim.create()
		local env = sim_env.create(sim)
		env:inject_env()
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
	local _, G = m2.ns.dynamic({"bit", "value"}, "uint32_t")
	local seen = {}

	local function notset() end
	local function set() G.value = G.value + G.bit end

	local br = m2.branch {
		m2.choice(0x1, notset),
		m2.choice(0x2, set)
	}

	m2.on("^firstbit", function()
		G.bit = 1
		G.value = 0
		br()
	end)

	m2.on("^nextbit", function()
		G.bit = G.bit * 2
		br()
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

test_fail_nobranch = with_env(function()
	local br = m2.branch {
		m2.choice(1, function() end)
	}

	m2.on("^branch", function()
		br()
	end)

	m2.on("nobranch", function()
		assert(fails(br))
	end)

	local instr = m2.record()
	instr.branch()
	instr.nobranch()

	return instr
end)

test_instr_checkpoint = with_env(function()
	local br = m2.branch {
		m2.choice(1, function() end)
	}

	local flag = false
	m2.on("^branch", function() end)
	m2.on("leaf", function() flag = true end)

	local instr = m2.record()
	instr.branch()
	instr.leaf()

	return instr, function() assert(flag) end
end)

test_branch_continue_chain = with_env(function()
	local seen = {}

	local x
	local function set(v)
		return function() x = v end
	end

	local br = m2.branch {
		m2.choice(0x1, set(1)),
		m2.choice(0x2, set(2)),
		m2.choice(0x3, set(3))
	}

	m2.on("^event", function()
		br()
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

test_vec_codegen = with_env(function()
	local V = m2.obj(bt.builtins {
		f32 = "real32",
		f64 = "real64",
		b8  = "bit8",
		b16 = "bit16",
		b32 = "bit32",
		b64 = "bit64",
		p   = "udata"
	})

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

test_vec_alloc = with_env(function()
	local V = m2.obj(bt.reals("a", "b"))
	local v = V:vec()
	v:newband("a")
	v:newband("b")

	for i=1, 100 do
		v:alloc(i)
		local a = ffi.cast("uintptr_t", v:band("a"))
		local b = ffi.cast("uintptr_t", v:band("b"))
		assert((a < b and a+v:len() < b) or (a > b and a > b+v:len()))
	end
end)

test_vmath_kernel_reduce = with_env(function()
	local sum = m2.kernel.vec():reduce(function(a, b) return a+b end, 0)
	local v = m2.allocv(3)
	v.data[0] = 1; v.data[1] = 2; v.data[2] = 3

	assert(sum(v) == 1+2+3)
end)

test_vmath_kernel_map = with_env(function()
	local sqsum = m2.kernel.vec():map(function(x) return x^2 end):sum()
	local v = m2.allocv(3)
	v.data[0] = 1; v.data[1] = 2; v.data[2] = 3

	assert(sqsum(v) == 1^2+2^2+3^2)
end)

test_vmath_kernel_multiple = with_env(function()
	local dot = m2.kernel.vec(2):map(function(x, y) return x*y end):sum()
	local x, y = m2.allocv(3), m2.allocv(3)
	x.data[0] = 1; x.data[1] = 2; x.data[2] = 3
	y.data[0] = 4; y.data[1] = 5; y.data[2] = 6

	assert(dot(x, y) == 1*4+2*5+3*6)
end)

test_obj_kernel = with_env(function()
	local V = m2.obj(bt.reals("a", "b"))
	local v = V:vec()
	v:alloc(3)
	local a = v:newband("a")
	local b = v:newband("b")
	a[0] = 1; a[1] = 2; a[2] = 3
	b[0] = 4; b[1] = 5; b[2] = 6

	local dot = m2.kernel.bands("a", "b"):map(function(x, y) return x*y end):sum()
	
	assert(dot(v) == 1*4+2*5+3*6)
end)

-- TODO: scheduler tests go here
