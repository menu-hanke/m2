-- vim: ft=lua
local control = require "control"

test_chain = function()
	local x = 0

	local b = control.chain(function(y) x = x*y end)
	local a = control.chain(function(y) x = x+y end, b)

	local continue_called = false
	a(function()
		continue_called = true
	end, 10)

	assert(continue_called)
	assert(x == (0+10)*10)
end

test_multi_continue = function()
	local x = 0
	local n = 0

	local function call3(continue, x, f)
		f(continue, x)
		f(continue, x)
		f(continue, x)
	end

	local b = control.chain(function(y) x = x+y end)
	local a = control.chain(function() return call3 end, b)

	a(function()
		n = n+1
	end, 5)

	assert(n == 3)
	assert(x == 15)
end

test_forward_jump = function()
	local c_called = false

	local c = control.chain(function() c_called = true end)
	local b = control.chain(function() assert(not "Don't call this") end, c)
	local a = control.chain(function() return c end, b)

	a(function() end)

	assert(c_called)
end

test_backward_jump = function()
	local x = 0

	local a

	local b = control.chain(function()
		x = x+1
	end, control.jump_f(function() return a end))

	a = control.chain(function()
		if x < 10 then
			return b
		end
	end)

	a(function() end)

	assert(x == 10)
end

test_self_loop = function()
	local x = 0

	local a = control.chain(function()
		if x == 10 then
			return control.exit
		end
		x = x+1
	end, "self")

	a(function() end)

	assert(x == 10)
end

test_bfunc = function()
	local x = 0

	local function call2(continue, x, f)
		f(continue, x)
		f(continue, x)
	end

	local bf = control.bfunc()
	bf:chain(function() return call2 end)
	bf:chain(function() x = x+1 end)

	local f = bf:compile()

	f(function() end)

	assert(x == 2)
end

test_eset = function()
	local x = 0

	local eset = control.eset()

	eset:on("add", function(n)
		x = x+n
	end)

	eset:on("reset", function()
		x = 0
	end)

	local events = eset:compile()

	control.event(events, "add", 1)
	control.event(events, "reset")
	control.event(events, "add", 2)

	assert(x == 2)
end

test_insn = function()
	local x = 0

	local eset = control.eset()

	eset:on("add", function(n)
		x = x+n
	end)

	local events = eset:compile()

	local rec = control.record()
	rec.add(1)
	rec.add(2)

	local insn = control.instruction(rec, events)
	insn()

	assert(x == 3)
end
