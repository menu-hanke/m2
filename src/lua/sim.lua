local ffi = require "ffi"
local C = ffi.C

-------------------------

local chain = {}
local chain_mt = { __index = chain }
local callback_mt = {}

local function create_chain(name)
	return setmetatable({}, chain_mt)
end

local function create_callback(f, prio)
	return setmetatable({f=f, prio=prio}, callback_mt)
end

function chain:add(cb)
	table.insert(self, cb)
	self:sort()
end

function chain:sort()
	table.sort(self)
end

function callback_mt:__lt(other)
	return self.prio < other.prio
end

function callback_mt:__call(...)
	return self.f(...)
end

-------------------------

local frame = {}
local frame_mt = { __index = frame }

local function create_frame(instr, ip)
	return setmetatable({instr=instr, ip=ip}, frame_mt)
end

local function xunpack(args, i, max)
	if i <= max then
		return args[i], xunpack(args, i+1, max)
	end
end

function frame:exec()
	while self.ip <= #self.instr do
		local instr = self.instr[self.ip]
		self.ip = self.ip + 1
		instr()

		if self.exit then
			return
		end
	end
end

function frame:continue()
	self:run_stack()
	if self.exit then return end
	self:exec()
end

function frame:mark_exit()
	self.exit = true
end

function frame:push(chain, args, narg)
	local ret = {
		chain = chain,
		narg = narg,
		args = args,
		next = 1
	}
	table.insert(self, ret)
	return ret
end

function frame:pop()
	self[#self] = nil
end

function frame:top()
	return self[#self]
end

function frame:copy()
	local ret = create_frame(self.instr, self.ip)

	for i,v in ipairs(self) do
		ret[i] = {
			chain = v.chain,
			narg = v.narg,
			args = v.args,
			next = v.next
		}
	end

	return ret
end

function frame:run_top(chain, args, narg)
	local sf = self:push(chain, args, narg)
	self:_run_subframe(sf)

	if self.exit then
		return
	end

	self:pop()
end

function frame:run_stack()
	while #self > 0 do
		local sub = self:top()
		self:_run_subframe(sub)

		if self.exit then
			return
		end

		self:pop()
	end
end

function frame:_run_subframe(sf)
	self:_call_subframe(sf, xunpack(sf.args, 1, sf.narg))
end

function frame:_call_subframe(sf, ...)
	local chain = sf.chain
	local n = #chain

	while sf.next <= n do
		local c = chain[sf.next]
		sf.next = sf.next + 1
		c(...)

		if self.exit then
			return
		end
	end
end

-------------------------

local record_mt = {}

function record_mt:__index(f)
	return function(...)
		table.insert(self.__recorded, {
			f = f,
			args = {...},
			narg = select("#", ...)
		})
	end
end

local function record()
	return setmetatable({__recorded={}}, record_mt)
end

local function getrecord(r)
	return r.__recorded
end

-------------------------

local sim = {}
local sim_mt = { __index = sim }
local chaintable_mt = {}

local function create_sim()
	local chains = setmetatable({}, chaintable_mt)
	local _sim = ffi.gc(C.sim_create(), C.sim_destroy)

	return setmetatable({
		chains = chains,
		_sim   = _sim,
		_frame = create_frame({}, 1)
	}, sim_mt)
end

local function choice(id, param)
	return {id=id, param=param}
end

local function generator(f)
	return function(...) return coroutine.wrap(f(...)) end
end

local function inject(env, sim)
	env.sim = sim
	env.record = record
	env.choice = choice
	env.generator = generator
	-- shortcuts
	env.on = delegate(sim, sim.on)
	env.branch = delegate(sim, sim.branch)
	env.event = delegate(sim, sim.event)
	env.simulate = delegate(sim, sim.simulate)
end

local function make_instr(sim, rec)
	local instr = {}

	for i,v in ipairs(rec) do
		local chain = sim.chains[v.f]
		local narg = v.narg
		local args = v.args

		instr[i] = function()
			return sim:eventv(chain, args, narg)
		end
	end

	return instr
end

function sim:on(event, f, prio)
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

	self.chains[event]:add(create_callback(f, prio))
end

function sim:simulate(rec)
	self:simulate_instr(make_instr(self, getrecord(rec)))
end

function sim:simulate_instr(instr)
	local f = self._frame
	self._frame = create_frame(instr, 1)
	self._frame:exec()
	self._frame = f
end

function sim:enter()
	C.sim_enter(self._sim)
end

function sim:savepoint()
	C.sim_savepoint(self._sim)
end

function sim:restore()
	C.sim_restore(self._sim)
end

function sim:exit()
	C.sim_exit(self._sim)
end

function sim:branch(instr, branches)
	local f = self._frame
	if f.exit then
		error("Can't branch on exiting frame")
	end

	-- TODO: this alloc is NYI, maybe use arena?
	local ids = ffi.new("sim_branchid[?]", #branches)
	local params = {}
	for i,v in ipairs(branches) do
		ids[i-1] = v.id
		params[tonumber(v.id)] = v.param
	end

	local id = C.sim_branch(self._sim, #branches, ids)

	if id ~= 0 then
		while id ~= 0 do
			self._frame = f:copy()
			instr(params[tonumber(id)])
			self._frame:continue()
			id = C.sim_next_branch(self._sim)
		end

		C.sim_exit(self._sim)
	end

	f:mark_exit()
	self._frame = f
end

function sim:event(event, ...)
	return self:eventv(self.chains[event], {...}, select("#", ...))
end

function sim:eventv(chain, args, narg)
	self._frame:run_top(chain, args, narg)
end

function chaintable_mt:__index(k)
	local ret = create_chain(k)
	self[k] = ret
	return ret
end

-------------------------

return {
	create = create_sim,
	inject = inject,
	record = record,
	choice = choice
}
