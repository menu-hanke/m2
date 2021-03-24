-- vim: ft=lua
local ffi = require "ffi"
local sim = require "sim"
local scripting = require "scripting"
local control = require "control"
local cfg = require "control.cfg"
local export = require "control.export"

local function exec(node, sim_)
	control.exec(control.compile(sim_ or sim.create(), node))
end

test_sanity = function()
	local called = false
	exec(function() called = true end)
	assert(called)
end

test_empty_all = function()
	local n = 0
	exec(cfg.all {
		cfg.all {},
		cfg.primitive(function() n=n+1 end)
	})
	assert(n == 1)
end

test_single_all = function()
	local n = 0
	exec(cfg.all {
		cfg.primitive(function() n=n+1 end)
	})
	assert(n == 1)
end

test_all = function()
	local n = 0
	exec(cfg.all {
		cfg.primitive(function() n = n+2 end),
		cfg.primitive(function() n = 2^n end)
	})
	assert(n == 4)
end

test_empty_any = function()
	local n = 0
	exec(cfg.all {
		cfg.any {},
		cfg.primitive(function() n=n+1 end)
	})
	assert(n == 0)
end

test_single_any = function()
	local n = 0
	exec(cfg.any {
		cfg.primitive(function() n=n+1 end)
	})
	assert(n == 1)
end

test_any = function()
	local sim = sim.create()
	local state = sim:new(ffi.typeof "struct { int which; }", "vstack")
	state.which = 0

	exec(cfg.all {
		cfg.any {
			cfg.primitive(function() assert(state.which == 0) state.which = 1 end),
			cfg.primitive(function() assert(state.which == 0) state.which = 2 end),
			cfg.primitive(function() assert(state.which == 0) state.which = 3 end),
		},
		cfg.primitive(function() assert(state.which ~= 0) end)
	}, sim)
end

test_nothing = function()
	local n = 0
	exec(cfg.all {
		cfg.primitive(function() n=n+1 end),
		cfg.nothing,
		cfg.primitive(function() n=n+2 end)
	})
	assert(n == 3)
end

test_optional = function()
	local sim = sim.create()
	local state = sim:new(ffi.typeof [[
		struct {
			uint32_t bit;
			uint32_t value;
		}
	]], "vstack")

	state.bit = 0
	state.value = 0
	local seen = {}

	local toggle = cfg.optional(cfg.primitive(function()
		state.value = state.value + 2^state.bit
	end))

	local nextbit = cfg.primitive(function()
		state.bit = state.bit + 1
	end)

	exec(cfg.all {
		toggle,
		nextbit,
		toggle,
		nextbit,
		toggle,
		cfg.primitive(function() seen[state.value] = true end)
	}, sim)

	for i=0, 7 do
		assert(seen[i])
	end
end

test_callstack_overwrite = function()
	local num = 0

	local branch = cfg.all {
		cfg.any {
			cfg.all{},
			cfg.all{}
		},
		cfg.all{}
	}

	exec(cfg.all {
		branch,
		branch,
		cfg.primitive(function() num = num + 1 end)
	})

	assert(num == 2^2)
end

test_deep_callstack = function()
	local num = 0

	local branch = cfg.all {
		cfg.any {
			cfg.all{},
			cfg.all{}
		},
		cfg.all{}
	}

	exec(cfg.all {
		cfg.all {
			cfg.all {
				cfg.all {
					cfg.all {
						cfg.all {
							branch,
							branch,
							branch,
							branch,
							cfg.primitive(function() num = num + 1 end)
						},
						cfg.all{}
					},
					cfg.all{}
				},
				cfg.all{}
			},
			cfg.all{}
		},
		cfg.all{}
	})

	assert(num == 2^4)
end

test_guard = function()
	local a, b = false, false

	exec(cfg.any {
		cfg.all {
			cfg.primitive(function() return false end),
			cfg.primitive(function() a = true end)
		},
		cfg.all {
			cfg.primitive(function() b = true end)
		}
	})

	assert(not a)
	assert(b)
end

test_recursion = function()
	local n = 0
	local node = cfg.all {
		cfg.primitive(function()
			if n == 10 then
				return false
			end
			n = n+1
		end)
	}

	table.insert(node.edges, node)
	exec(node)
	assert(n == 10)
end

test_custom_func = function()
	local n = 0

	exec(cfg.all {
		function(stack, bottom, top)
			local continue, top = stack[top], top-1
			for i=1, 10 do
				continue(control.copystack(stack, bottom, top))
			end
		end,
		cfg.primitive(function() n = n+1 end)
	})

	assert(n == 10)
end

test_primitive_args = function()
	local n = 0

	exec(cfg.primitive(function(x, y)
		n = n+x*y
	end, 2, {3, 4}))

	assert(n == 12)
end

test_chain_primitive_args = function()
	local n = 0

	exec(cfg.all {
		cfg.primitive(function(x) n = n+x end, 1, {2}),
		cfg.primitive(function(y) n = n*y end, 1, {-1})
	})

	assert(n == -2)
end

test_export = function()
	local n = 0

	local insn = cfg.all {
		cfg.export("f", 2, {1, 3}),
		cfg.export("g", 1, {-4})
	}

	export.patch_exports(insn, {
		f = function(x, y)
			n = n+x+y
		end,
		g = export.make_primitive(function(x)
			return function(y)
				n = x*n/y
			end, 2
		end)
	})

	exec(insn)

	assert(n == -8) -- 4*(-4)/2
end

test_scripting = function()
	local sim = sim.create()
	local env = scripting.env(sim)
	control.inject(env)

	local n = 0
	function env.m2.export.f(x)
		n = n+x
	end

	local cenv = control.env()
	local insn = setfenv(function()
		return all {
			getfenv().sim.f(1)
		}
	end, cenv)()

	export.patch_exports(insn, env.m2.export)
	exec(insn, sim)

	assert(n == 1)
end
