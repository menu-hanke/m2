local m2 = require "m2"
local ffi = require "ffi"

local state = m2.new(ffi.typeof [[
	struct {
		int idx;
		float time;
	}
]], "vstack")

state.idx = 0
state.time = 0
local stack = {}

local branch = m2.events()
	:provide({
		op = function(x)
			return function()
				state.idx = state.idx + 1
				stack[state.idx] = string.format("%s (%f)", x, state.time)
			end
		end
	})
	:create()

m2.on("step", function(T)
	state.time = T
	return branch(T)
end)

m2.on("step#1", function()
	local s = {}
	for i=1, state.idx do
		s[i] = stack[i]
	end

	print(table.concat(s, " -> "))
end)
