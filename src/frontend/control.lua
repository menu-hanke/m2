local code = require "code"

---- branch function primitives ----------------------------------------

local function chain(f, g)
	local src = code.new()
	local tail = type(g) == "function" and "_next" or g == "self" and "f"

	src:emit([[
		local _next = _next
		local _f = _f

		local function f(continue, x)
			local branch = _f(x)
			if branch then
	]])

	if tail then
		src:emitf("return branch(continue, x, %s)", tail)
	else
		src:emit("return branch(continue, x, continue)")
	end

	src:emit("end")

	if tail then
		src:emitf("return %s(continue, x)", tail)
	else
		src:emit("return continue()")
	end

	src:emit("end")

	src:emit("return f")

	return src:compile({_f=f, _next=g}, string.format("=(chain@%s->%s)", f, g))()
end

local function nop() end

local function chain_continue(f, x, continue)
	return code.new():emit([[
		local _f = _f
		local _x = _x
		local _continue = _continue

		return function()
			return _f(_continue, _x)
		end
	]]):compile({_f=f, _x=x, _continue=continue or nop},
		string.format("=(continue@%s->%s)", f, continue))()
end

local function jump(g, y)
	return code.new():emit([[
		local _g = _g
		local _y = _y

		return function(continue)
			return _g(continue, _y)
		end
	]]):compile({_g=g, _y=y}, string.format("=(jump@%s)", g))()
end

local function jump_f(g, y)
	return code.new():emit([[
		local _g = _g
		local _y = _y

		return function(continue, x)
			local g = _g(x)
			return g(continue, _y)
		end
	]]):compile({_g=g, _y=y}, string.format("=(jumpf@%s)", g))()
end

local function exit(continue)
	continue()
end

local function cont(continue, x, f)
	return f(continue, x)
end

local resume_mt = { __call = function(self) return self.f(self.continue, self.x) end }
local function resume(continue, x, f)
	return setmetatable({continue=continue, x=x, f=f}, resume_mt)
end

local function call(g, y)
	return code.new():emit([[
		local _g = _g
		local _y = _y
		local _resume = resume

		return function(continue, x, f)
			return _g(_y, resume(continue, x, f))
		end
	]]):compile({_g=g, _y=y, resume=resume}, string.format("=(call@%s)", g))()
end

---- branch function creation ----------------------------------------

local bfunc_mt = { __index = {} }

local function bfunc()
	return setmetatable({}, bfunc_mt)
end

function bfunc_mt.__index:chain(f, prio)
	table.insert(self, {f=f, prio=prio, order=#self})
	return self
end

function bfunc_mt.__index:sort()
	table.sort(self, function(a, b)
		if a.prio ~= b.prio then return a.prio < b.prio end
		return a.order < b.order
	end)
end

function bfunc_mt.__index:compile()
	if #self == 0 then return exit end

	self:sort()

	local f = nil
	for i=#self, 1, -1 do
		f = chain(self[i].f, f)
	end

	return f
end

---- event set ----------------------------------------

local eset_mt = { __index = {} }

local function eset()
	return setmetatable({ events={} }, eset_mt)
end

function eset_mt.__index:on(event, f, prio)
	if not prio then
		local e, p = event:match("([^#]*)#?([%-%+]?%d*)")
		event = e
		prio = tonumber(p)
	end

	if not self.events[event] then
		self.events[event] = bfunc()
	end

	self.events[event]:chain(f, prio or 0)
end

function eset_mt.__index:compile()
	local events = {}

	for event,bf in pairs(self.events) do
		events[event] = bf:compile()
	end

	return events
end

---- instruction ----------------------------------------

local function record()
	local insn = {}
	return setmetatable({}, {
		__index = function(_, f)
			return function(x)
				table.insert(insn, {f=f, x=x})
			end
		end,

		insn = insn
	})
end

local function getrecord(r)
	return getmetatable(r).insn
end

local function compile_insn(insn, events)
	local f = nop

	for i=#insn, 1, -1 do
		local e = events[insn[i].f]
		if e then
			f = chain_continue(e, insn[i].x, f)
		end
	end

	return f
end

--------------------------------------------------------------------------------

local function event(events, name, x)
	local f = events[name]
	if f then return f(nop, x) end
end

local function inject(env)
	env.m2.record = record

	env.m2.control = {
		chain = chain,
		chain_continue = chain_continue,
		jump = jump,
		jump_f = jump_f,
		exit = exit,
		call = call
	}
end

return {
	chain = chain,
	chain_continue = chain_continue,
	jump = jump,
	jump_f = jump_f,
	exit = exit,
	cont = cont,
	call = call,

	bfunc = bfunc,
	eset = eset,
	record = record,
	instruction = function(rec, events) return compile_insn(getrecord(rec), events) end,
	event = event,
	inject = inject
}
