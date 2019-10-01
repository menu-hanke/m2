local code = require "code"
local ffi = require "ffi"
local C = ffi.C

local sched_mt = { __index={} }
local evdef_mt = { __index={_prio=0} }

local function create(tags)
	local ret = setmetatable({
		events     = {},
		tags_prio  = {}
	}, sched_mt)

	if tags then
		ret:tags(tags)
	end

	return ret
end

local function inject(env)
	env.scheduler = function(tags)
		local ret = create(tags)
		env.on("sim:compile", function() ret:compile(env.sim) end)
		return ret
	end
end

function sched_mt:__call(year)
	return self.run(year)
end

--------------------------------------------------------------------------------

local tag_mt = { __index={} }
local tagset_mt = { __index={} }

local function newtag(tag, prio)
	return setmetatable({
		tag    = tag,
		prio   = prio,
		forced = {},
		choices = {}
	}, tag_mt)
end

local function tagset(tags)
	local tset = setmetatable({tags={}, lookup={}}, tagset_mt)

	local idx = 0
	for tag,prio in pairs(tags) do
		local t = newtag(tag, prio)
		t.idx = idx
		table.insert(tset.tags, t)
		tset.lookup[tag] = t
		idx = idx + 1
	end

	table.sort(tset.tags)

	return tset
end

function tag_mt:__lt(other)
	if self.prio == other.prio then return self.tag < other.tag end
	return self.prio < other.prio
end

function tagset_mt.__index:primary(ev)
	local ret = self.lookup[ev._tags[1]]

	for i=2, #ev._tags do
		local tag = self.lookup[ev._tags[i]]
		if tag < ret then
			ret = tag
		end
	end

	return ret
end

function tagset_mt.__index:add_event(ev)
	local tag = self:primary(ev)
	table.insert(ev._forced and tag.forced or tag.choices, ev)
end

function tagset_mt.__index:nonempty()
	local ret = {}

	for _,t in ipairs(self.tags) do
		if #t.forced > 0 or #t.choices > 0 then
			table.insert(ret, t)
		end
	end

	return ret
end

function tagset_mt.__index:map_tags(ev, f)
	local tag_idx = {}

	for _,t in ipairs(ev._tags) do
		table.insert(tag_idx, f(self.lookup[t]))
	end

	return tag_idx
end

function tagset_mt.__index:emit_condition(code, upvalues, tag, event)
	if not event._cond then
		return
	end

	local hist_tags = self:map_tags(event, function(t)
		return string.format("hist[%d]", t.idx)
	end)

	-- TODO: preceding events, maybe make a wrapper of the hist array
	-- and put it here
	code:emitf([[
		local function cond_%s(time)
			local prev = max(%s)
			return xcond_%s(time, prev)
		end
	]], event.evid, table.concat(hist_tags, ","), event.evid)

	upvalues[string.format("xcond_%s", event.evid)] = event._cond
end

function tagset_mt.__index:emit_event(code, upvalues, tag, event)
	local hist_update = self:map_tags(event, function(t)
		return string.format("hist[%d] = time", t.idx)
	end)

	code:emitf([[
		local function event_%s(time)
			xevent_%s()
			%s
		end
	]], event.evid, event.evid, table.concat(hist_update, "; "))

	upvalues[string.format("xevent_%s", event.evid)] = event._callback
end

function tagset_mt.__index:emit_eventlist(code, upvalues, tag)
	for _,e in ipairs(tag.forced) do
		self:emit_condition(code, upvalues, tag, e)
		self:emit_event(code, upvalues, tag, e)
	end

	for _,e in ipairs(tag.choices) do
		self:emit_condition(code, upvalues, tag, e)
		self:emit_event(code, upvalues, tag, e)
	end
end

function tagset_mt.__index:emit_tagfunc(code, tag, prev)
	code:emitf("local function tag_%s(time)", tag.tag)

	for _,e in ipairs(tag.forced) do
		-- forced events should have a condition
		code:emitf("if cond_%s(time) then", e.evid)
		code:emitf("event_%s(time)", e.evid)
		if prev then
			code:emitf("tag_%s(time)", prev.tag)
		else
			code:emit("return")
		end
		code:emit("end")
	end

	if #tag.choices > 0 then
		-- TODO: there's 2 options to implement ignoring some conditions in re-simulation here:
		-- (1) just skip the conditions and dump everything to branch()
		-- (2) pass a 'resimulation' parameter to each condition function and let them decide

		-- this do-nothing branch is needed because some events sharing tags may have a different
		-- primary tag so they won't be otherwise simulated as alternatives
		-- (e.g. consider event e1 with tags A,B and e2 with tag B, without a do-nothing branch
		-- the only alternative is e1 and it will block e2.)
		-- the do-nothing branch always has id=1
		code:emit([[
			branches[0] = 1
			local nb = 1
		]])

		for _,e in ipairs(tag.choices) do
			if e._cond then
				code:emitf("if cond_%s(time) then", e.evid)
			end

			code:emitf([[
				branches[nb] = %d
				nb = nb+1
			]], e.evid)

			if e._cond then
				code:emit("end")
			end
		end

		-- Note: if this starts causing trace aborts because of too long traces,
		-- then this can be transformed into a loop. If there's not a huge number
		-- then it will only spawn a few side traces and all is OK
		local cont = prev and string.format("tag_%s(time)", prev.tag) or "sim:continuenew()"
		code:emitf([[
			C.sim_branch(_sim, nb, branches)
			if C.sim_next_branch(_sim) then
				%s
				C.sim_exit(_sim)
			end
		]], cont)

		for _,e in ipairs(tag.choices) do
			code:emitf([[
				if C.sim_next_branch(_sim) then
					event_%s(time)
					%s
					C.sim_exit(_sim)
				end
			]], e.evid, cont)
		end

		if not prev then
			code:emit("sim:exitframe()")
		end
	end

	code:emit("end")
end

function tagset_mt.__index:emit_tag(code, upvalues, tag, prev)
	self:emit_eventlist(code, upvalues, tag)
	self:emit_tagfunc(code, tag, prev)
end

function tagset_mt.__index:emit_wrapper(code, tag)
	code:emitf("return tag_%s", tag.tag)
end

function tagset_mt.__index:maxchoice()
	local ret = 0

	for _,t in ipairs(self.tags) do
		if #t.choices > ret then
			ret = #t.choices
		end
	end

	return ret
end

function tagset_mt.__index:emit_upvalues(upvalues, sim)
	local maxc = self:maxchoice()
	-- we can safely share the branch buffer, sim will make a copy when we call
	-- C.sim_branch()
	-- alloc 1 extra for do-nothing branch
	upvalues.branches = ffi.new("sim_branchid[?]", maxc+1)
	upvalues.hist = ffi.cast("double *", sim:alloc(
		ffi.sizeof("double") * #self.tags,
		ffi.alignof("double"),
		C.SIM_MUTABLE + C.SIM_FRAME
	))
	upvalues.sim = sim
	upvalues._sim = sim._sim
	upvalues.max = math.max
	upvalues.C = C

	for i=0, #self.tags-1 do
		upvalues.hist[i] = 0
	end
end

function tagset_mt.__index:compile(sim)
	local tags = self:nonempty()
	if #tags == 0 then
		return function() end
	end

	local code = code.new()
	local upvalues = {}

	-- compile tags in reverse order to have the first tag be the outermost one
	for i=#tags, 1, -1 do
		self:emit_tag(code, upvalues, tags[i], tags[i+1])
	end

	self:emit_upvalues(upvalues, sim)
	self:emit_wrapper(code, tags[1])

	--print(code)
	return code:compile(upvalues, "=(scheduler)")()
end

--------------------------------------------------------------------------------

function sched_mt.__index:compile(sim)
	local ts = tagset(self.tags_prio)
	table.sort(self.events, function(a, b) return a._prio < b._prio end)
	for _,e in ipairs(self.events) do
		ts:add_event(e)
	end

	self.run = ts:compile(sim)

	-- we don't need these anymore
	self.events = nil
	self.tags_prio = nil
	self.event = function() error("Can't define new events after simulation start") end
	self.tags = function() error("Can't add tags after simulation start") end
end

function sched_mt.__index:event(evid)
	local evdef = setmetatable({evid=evid}, evdef_mt)
	table.insert(self.events, evdef)
	return evdef
end

function sched_mt.__index:tags(tags)
	for tag,prio in pairs(tags) do
		self.tags_prio[tag] = prio
	end
end

function evdef_mt.__index:tags(...)
	self._tags = {...}
	return self
end

function evdef_mt.__index:forced()
	self._forced = true
	return self
end

function evdef_mt.__index:check(cond)
	self._cond = cond
	return self
end

function evdef_mt.__index:run(cb)
	self._callback = cb
	return self
end

function evdef_mt.__index:priority(prio)
	self._prio = prio
	return self
end

--------------------------------------------------------------------------------

return {
	create = create,
	inject = inject
}
