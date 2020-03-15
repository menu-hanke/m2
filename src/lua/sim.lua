local code = require "code"
local misc = require "misc"
local jit = require "jit"
local ffi = require "ffi"
local C = ffi.C

--------------------------------------------------------------------------------

local chain_mt = { __index = {} }

local function create_chain(name)
	return setmetatable({name=name}, chain_mt)
end

function chain_mt.__index:add(f, prio, branch)
	table.insert(self, {f=f, prio=prio, order=#self, branch=branch})
end

function chain_mt.__index:sort()
	-- table.sort isn't stable so we have to make it stable to preserve chain order across runs
	table.sort(self, function(a, b)
		if a.prio ~= b.prio then return a.prio < b.prio end
		return a.order < b.order
	end)
end

function chain_mt.__index:branch()
	for i=1, #self do
		if self[i].branch then
			return true
		end
	end
	return false
end

-- Compile an event chain function from the callbacks.
-- This is done because the jit will generate garbage code if we just call the function array
-- inside a loop.
-- The strategy is to generate "checkpoint" functions: a new function is started for every
-- position the simulation can return to after branching, ie. after every event that is allowed to
-- branch. Inside the checkpoint function are inserted calls to the event functions and branching
-- checks for the exit branching function, then a tailcall to the next checkpoint
--
-- Example generated code:
--
--     local f1, ..., fN = chain[1].f, ..., chain[N].f
--
--     local function cp2(frame, x)
--         ...
--     end
--
--     local function cp1(frame, x)
--         frame.branch = false
--         f1(x)                -- not branching
--         f2(x)                -- not branching
--         frame.branch = true
--         frame.ep = 2         -- where to return after branch - checkpoint #2
--         f3(x)                -- may branch
--         -- branch exit check
--         if frame.exit then return true end
--         return cp2(frame, x) -- tailcall to next checkpoint
--     end
--
--     return {
--         cp1,
--         cp2
--     }
--

local function compile_checkpoint(chain, idx, cpidx)
	local out = code.new()
	local branch = chain[idx].branch

	local info = debug.getinfo(chain[idx].f)

	out:emitf("local function cp%d(frame, x)", cpidx)

	-- head (non-branch functions)
	if not branch then
		out:emit("\tframe.branch = false")
		while not branch do
			out:emitf("\tf%d(x) -- event #%s", idx, chain[idx].order or "(default)")
			idx = idx+1
			if idx > #chain then break end
			branch = chain[idx].branch
		end
	end

	-- tail (exit branch or chain end)
	if branch then
		out:emit("\tframe.branch = true")
		-- if this is the last checkpoint then this points over the end of the array
		-- this is ok and intentional, it means the chain is done
		out:emitf("\tframe.ep = %d", cpidx+1)
		out:emitf("\tf%d(x) -- tail #%s", idx, chain[idx].order or "(default)")
		idx = idx+1

		if idx > #chain then
			-- this was the last checkpoint, we're leaving the event chain and the branch flag
			-- is currently set, so it needs to be cleared
			out:emit("\tframe.branch = false")
			out:emit("\treturn frame.exit")
		else
			-- not the last checkpoint, exit if branched and tailcall to next checkpoint
			out:emit("\tif frame.exit then return true end")
			out:emitf("\treturn cp%d(frame, x)", cpidx+1)
		end
	else
		-- exit chain without branch, the branch flag must be false now, so nothing left to do
		assert(idx > #chain)
	end

	out:emit("end")

	return tostring(out), string.format("cp%d", cpidx), idx
end

local function compile_chain(chain)
	if #chain == 0 then return function() end end

	local out = code.new()

	-- prologue (store callbacks in locals)
	for i=1, #chain do
		out:emitf("local f%d = chain[%d].f", i, i)
	end

	local checkpoints, cpnames = {}, {}
	local cp, name, idx = nil, nil, 1
	while idx <= #chain do
		cp, name, idx = compile_checkpoint(chain, idx, #checkpoints+1)
		cpnames[#checkpoints+1] = name
		checkpoints[#checkpoints+1] = cp
	end

	for i=#checkpoints, 1, -1 do
		out:emit(checkpoints[i])
	end

	out:emitf("return {%s}", table.concat(cpnames, ", "))
	return out:compile({chain=chain}, string.format("=(chain@%s)", chain.name))()
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

-- Compile the the simulation instructions (event chain calls, basically)
-- This used to be a loop in lua, but then luajit will see it and attempt to compile it,
-- resulting in catastrophic failure.

-- Same idea as in compile_checkpoint() for chains, but we don't need to mind the frame flags here
local function compile_icp(sim, instr, idx, cpidx)
	local out = code.new()
	out:emitf("local function icp%d(frame)", cpidx)

	local branch = sim.chains[instr[idx].f].branch
	while not branch do
		out:emitf("\te%d(frame, x%d) -- event: %s (%s)", idx, idx, instr[idx].f, instr[idx].arg)
		idx = idx+1
		if idx > #instr then break end
		branch = sim.chains[instr[idx].f].branch
	end

	if branch then
		out:emitf("\tframe.ip = %d", cpidx+1)
		out:emitf("\tif e%d(frame, x%d) -- tail: %s (%s)", idx, idx, instr[idx].f, instr[idx].arg)
		out:emitf("\t\tthen return true end")
		idx = idx+1
	end

	if idx <= #instr then
		out:emitf("\treturn icp%d(frame)", cpidx+1)
	end

	out:emit("end")
	return tostring(out), string.format("icp%d", cpidx), idx
end

local function compile_instr(sim, instr)
	local out = code.new()

	for i=1, #instr do
		out:emitf("local e%d = sim.chains[instr[%d].f].checkpoints[1]", i, i)
		out:emitf("local x%d = instr[%d].arg", i, i)
	end

	local icp, icpname = {}, {}
	local tails, xs = {}, {}
	local c, n, idx = nil, nil, 1
	while idx <= #instr do
		c, n, idx = compile_icp(sim, instr, idx, #icp+1)
		tails[#icp+1] = string.format("sim.chains[instr[%d].f].checkpoints", idx-1)
		xs[#icp+1] = string.format("x%d", idx-1)
		icpname[#icp+1] = n
		icp[#icp+1] = c
	end

	for i=#icp, 1, -1 do
		out:emit(icp[i])
	end

	out:emitf("return {checkpoints={%s}, tails={%s}, xs={%s}}",
		table.concat(icpname, ", "),
		table.concat(tails, ", "),
		table.concat(xs, ",")
	)
	return out:compile({sim=sim, instr=instr}, string.format("=(instr@%p)", instr))()
end

--------------------------------------------------------------------------------

local frame_ct = ffi.typeof [[
	struct {
		int ip, ep;
		bool branch, exit;
	}
]]

local stack_mt = { __index = {} }

local function stack(instr)
	return setmetatable({
		fp    = 0
	}, stack_mt)
end

local function pushframe(stk)
	stk.fp = stk.fp+1
	local new = stk[stk.fp]

	if not new then
		new = frame_ct()
		stk[stk.fp] = new
	end

	return new
end

local function popframe(stk)
	stk.fp = stk.fp-1
end

function stack_mt.__index:exec(instr)
	local top = pushframe(self)
	top.ip = 1
	top.exit = false
	-- event chains control frame.branch and frame.ep

	local _icp = self.icp
	local _tail = self.tail
	local _x = self.x

	self.icp  = instr.checkpoints
	self.tail = instr.tails
	self.x    = instr.xs

	self.icp[1](top)

	self.icp  = _icp
	self.tail = _tail
	self.x    = _x

	popframe(self)
end

function stack_mt.__index:event(ecp, y)
	local top = pushframe(self)
	top.ip = -1 -- <0 indicates not inside instruction
	top.exit = false
	-- event chain will control frame.branch, no need to set it here
	-- same for frame.ep

	local _ecp = self.ecp
	local _y = self.y

	self.ecp = ecp
	self.y = y

	ecp[1](top, y)

	self.ecp = _ecp
	self.y = _y

	popframe(self)
end

local function continueframe(stk, frame, top)
	if frame.ip < 0 then
		return stk.ecp[frame.ep](top, stk.y)
	end

	if frame.ip > 1 then
		local ep = stk.tail[frame.ip-1][frame.ep]
		if ep then
			if ep(top, stk.x[frame.ip-1]) then
				return true
			end
		end
	end

	local ip = stk.icp[frame.ip]
	if ip then
		return ip(top)
	end
end

function stack_mt.__index:continue()
	local frame = self[self.fp]

	if not frame.branch then error("Not allowed to continue from this frame") end

	-- now that this frame has branched it should exit when control returns to it
	frame.exit = true

	local top = pushframe(self)
	top.ip     = frame.ip -- may branch again inside same chain so icp wont set ip
	top.branch = true -- event chain expects this to be preserved
	top.exit   = false

	continueframe(self, frame, top)
	popframe(self)
end

--------------------------------------------------------------------------------

local sim_mt = { __index = {} }

local function create_sim()
	local _sim = ffi.gc(C.sim_create(), C.sim_destroy)

	return setmetatable({
		chains = {},
		stack  = stack(),
		_sim   = _sim
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
	env.m2.on = misc.delegate(sim, sim.on)
	env.m2.branch = misc.delegate(sim, sim.branch)
	env.m2.event = misc.delegate(sim, sim.event)
end

function sim_mt.__index:on(event, f, config)
	if self._compiled then
		error(string.format("Can't install event handler (%s) after simulation has started", event))
	end

	if not config then
		local b,e,p = event:match("(%^?)([^#]*)#?([%-%+]?%d*)")
		event = e
		config = {
			branch = b == "^",
			prio = tonumber(p) or 0
		}
	end

	if not self.chains[event] then
		self.chains[event] = create_chain(event)
	end

	self.chains[event]:add(f, config.prio or 0, config.branch or false)
end

function sim_mt.__index:compile()
	for event,chain in pairs(self.chains) do
		chain:sort()
		local checkpoints = compile_chain(chain)
		self.chains[event] = {
			checkpoints = checkpoints,
			branch      = chain:branch()
		}
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

function sim_mt.__index:event(event, x)
	local chain = self.chains[event]

	if chain then
		self.stack:event(chain.checkpoints, x)
	end
end

function sim_mt.__index:simulate(instr)
	self.stack:exec(instr)
end

function sim_mt.__index:continue()
	self.stack:continue()
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
				self:continue()
				C.sim_exit(self._sim)
			end
		end
	end
end

--------------------------------------------------------------------------------

return {
	create = create_sim,
	inject = inject,
	record = record,
	choice = choice
}
