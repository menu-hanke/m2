local code = require "code"
local aux = require "aux"
local jit = require "jit"
local ffi = require "ffi"
local C = ffi.C

--------------------------------------------------------------------------------

local chain_mt = { __index = {} }

local function create_chain(name)
	return setmetatable({name=name}, chain_mt)
end

function chain_mt.__index:add(f, prio)
	table.insert(self, {f=f, prio=prio})
end

function chain_mt.__index:sort()
	table.sort(self, function(a, b) return a.prio < b.prio end)
end

-- Compile all callbacks in a single function so the jit can inline them.
-- If we just put them in an array and call that array in a loop, the jit will spam
-- side traces for each array element.
-- The generated code will look something like this:
--
-- local f1 = chain[1]
-- ...
-- local fn = chain[n]
-- local cn = function(frame, flags, x) frame.next=nil; fn(x) end
-- ...
-- local c2 = function(fr,fl,x) fr.next = c3; f2(x); if fl.exit then return end; c3(fr,fl,x) end
-- local c1 = function(fr,fl,x) fr.next = c2; f1(x); if fl.exit then return end; c2(fr,fl,x) end
-- return c1
--
-- Then c1 is our event chain and the jit will compile it like we want!
function chain_mt.__index:compile()
	if #self == 0 then return function() end end
	self:sort()

	local ret = code.new()

	for i=1, #self do
		ret:emitf("local f%d = chain[%d].f", i, i)
	end

	ret:emitf([[
		local c%d = function(frame, flags, x)
			frame.next = nil
			f%d(x)
		end
	]], #self, #self)

	for i=#self-1, 1, -1 do
		ret:emitf([[
			local c%d = function(frame, flags, x)
				frame.next = c%d
				f%d(x)
				if flags.exit then return end
				c%d(frame, flags, x)
			end
		]], i, i+1, i, i+1)
	end

	ret:emit("return c1")
	
	return ret:compile({chain=self}, string.format("=(chain@%s)", self.name))()
end

--------------------------------------------------------------------------------

local record_mt = {}

function record_mt:__index(f)
	return function(x)
		table.insert(self.__recorded, { f = f, arg = x })
	end
end

local function record()
	return setmetatable({__recorded={}}, record_mt)
end

local function getrecord(r)
	return r.__recorded
end

local function compile_instr(sim, instr)
	local e = {}
	local x = {}
	local num = #instr

	for i=1, num do
		e[i] = sim.chains[instr[i].f]
		x[i] = instr[i].arg
	end

	local ret = function(frame, ip)
		ip = ip or 1
		local flags = frame.flags
		for i=ip, num do
			frame.ip = i
			frame.x = x[i]
			e[i](frame, flags, x[i])
			if flags.exit then return end
		end
	end

	-- Note: this generates a lot of side trace spam but testing shows it's still
	-- still better to compile this.
	-- (TODO: should test how this works with a lot of events, since it will basically
	-- spawn a side trace per event chain)
	--jit.off(ret)

	return ret
end

--------------------------------------------------------------------------------

-- frame flags is a ctype to avoid spamming table lookups in the event chain
-- (this is a micro optimization but it does help noticeably if the event chain is a long
-- chain of small events)
local frame_flags = ffi.typeof("struct { bool exit; }")

local frame_mt = { __index={} }

local function frame(prev)
	return setmetatable({ prevframe=prev, flags = frame_flags() }, frame_mt)
end

function frame_mt.__index:setins(instr)
	self.instr = instr
	self.ip = 1
end

function frame_mt.__index:exec()
	self.instr(self)
end

function frame_mt.__index:event(ev, x)
	return ev(self, self.flags, x)
end

function frame_mt.__index:continue()
	if self.next then
		self:event(self.next, self.x)
	end

	if not self.flags.exit then
		self.instr(self, self.ip+1)
	end
end

function frame_mt.__index:copy(from)
	self.instr = from.instr
	self.ip    = from.ip
	self.next  = from.next
	self.x     = from.x
	self.flags.exit = false
end

function frame_mt.__index:push()
	self.nextframe = self.nextframe or frame(self)
	self.nextframe:copy(self)
	return self.nextframe
end

--------------------------------------------------------------------------------

local sim_mt = { __index = {} }

local function create_sim()
	local _sim = ffi.gc(C.sim_create(), C.sim_destroy)

	return setmetatable({
		chains = {},
		_sim   = _sim,
		_frame = frame()
	}, sim_mt)
end

local function choice(id, func)
	return {id=id, func=func}
end

local function inject(env)
	local sim = env.sim
	env.m2.sim = sim
	env.m2.record = record
	env.m2.choice = choice
	-- shortcuts
	env.m2.on = aux.delegate(sim, sim.on)
	env.m2.branch = aux.delegate(sim, sim.branch)
	env.m2.event = aux.delegate(sim, sim.event)
end

function sim_mt.__index:on(event, f, prio)
	if self._compiled then
		error(string.format("Can't install event handler (%s) after simulation has started", event))
	end

	if not prio then
		-- allow specifying prio in event string like "event#prio"
		local e,p = event:match("(.-)#([%-%+]?%d+)")
		if e then
			event = e
			prio = tonumber(p)
		else
			prio = 0
		end
	end

	if not self.chains[event] then
		self.chains[event] = create_chain(event)
	end

	self.chains[event]:add(f, prio)
end

function sim_mt.__index:compile()
	for event,chain in pairs(self.chains) do
		self.chains[event] = chain:compile()
	end

	self._compiled = true

	self:event("sim:compile")
end

function sim_mt.__index:compile_instr(r)
	if not self._compiled then
		error("Can't compile instructions before simulation start. Call sim:compile() first.")
	end

	return compile_instr(self, getrecord(r))
end

function sim_mt.__index:simulate(instr)
	self._frame = self._frame:push()
	self._frame:setins(instr)
	self._frame:exec()
	self._frame = self._frame.prevframe
end

function sim_mt.__index:continuenew()
	self._frame = self._frame:push()
	self._frame:continue()
	self._frame = self._frame.prevframe
end

function sim_mt.__index:exitframe()
	self._frame.flags.exit = true
end

function sim_mt.__index:event(event, x)
	if self.chains[event] then
		self._frame:event(self.chains[event], x)
	end
end

function sim_mt.__index:enter()
	C.sim_enter(self._sim)
end

function sim_mt.__index:savepoint()
	C.sim_savepoint(self._sim)
end

function sim_mt.__index:restore()
	C.sim_restore(self._sim)
end

function sim_mt.__index:exit()
	C.sim_exit(self._sim)
end

function sim_mt.__index:alloc(size, align, life)
	return (C.sim_alloc(self._sim, size, align, life))
end

function sim_mt.__index:allocator(ct, life)
	local rt = ct .. "*"
	local size = ffi.sizeof(ct)
	local align = ffi.alignof(ct)
	life = life or ffi.C.SIM_FRAME

	return function(n)
		n = n or 1
		return (ffi.cast(rt, self:alloc(n * size, align, life)))
	end
end

function sim_mt.__index:branch(choices)
	local nb = #choices
	local branches = ffi.new("sim_branchid[?]", nb)

	for i=1, nb do
		branches[i-1] = choices[i].id
	end

	return function(x)
		C.sim_branch(self._sim, nb, branches)

		-- Note: this loop may cause trace aborts / unnecessary side traces.
		-- if/when this causes performance problems replace it with code generation.
		for i=1, nb do
			if C.sim_next_branch(self._sim) then
				choices[i].func(x)
				self:continuenew()
				C.sim_exit(self._sim)
			end
		end

		self:exitframe()
	end
end

--------------------------------------------------------------------------------

return {
	create = create_sim,
	inject = inject,
	record = record,
	choice = choice
}
