local bitset = require "bitset"
local code = require "code"
local control = require "control"
local ffi = require "ffi"

local plan_mt = { __index={} }
local eset_mt = { __index={} }

local egen_mt = { __index={} }
local branch_mt = { __index={} }

local function propagate_after(events, e)
	if e._after then
		return
	end

	if e._mark then
		error(string.format("Event '%s' must come after itself (cycle)", e.name))
	end

	e._mark = true

	for i in bitset.bits(e.after) do
		local v = events[i+1]
		propagate_after(events, v)
		bitset.union(e.after, v.after)
	end

	e._after = true
	e._mark = nil
end

local function match_events(events, f)
	return coroutine.wrap(function()
		for _,e in ipairs(events) do
			if f(e.event) then
				coroutine.yield(e)
			end
		end
	end)
end

local function egen(def, ops)
	local events = {}

	for _,e in pairs(def.events) do
		if ops[e.op.f] then
			table.insert(events, {
				event = e,
				i = #events,
				f = ops[e.op.f](unpack(e.op.x))
			})
		end
	end

	local N = #events
	for _,e in ipairs(events) do
		e.after = bitset.create(N)
		e.requires = bitset.create(N)
		e.blocked_by = bitset.create(N)
	end

	events.N = N

	-- XXX blocked_by / requires should be separate, this should be checked?

	for _,e in ipairs(events) do
		if e.event.before then
			for v in match_events(events, e.event.before) do
				v.after[e.i] = true
			end
		end

		if e.event.after then
			for v in match_events(events, e.event.after) do
				e.after[v.i] = true
			end
		end

		if e.event.requires then
			for v in match_events(events, e.event.requires) do
				e.after[v.i] = true
				e.requires[v.i] = true
			end
		end

		if e.event.blocks then
			for v in match_events(events, e.event.blocks) do
				v.blocked_by[e.i] = true
			end
		end

		if e.event.blocked_by then
			for v in match_events(events, e.event.blocked_by) do
				e.blocked_by[v.i] = true
			end
		end
	end

	for _,e in ipairs(events) do
		propagate_after(events, e)
	end

	table.sort(events, function(a, b)
		if b.after[a.i] then return true end
		if a.after[b.i] then return false end
		return a.event.order < b.event.order
	end)

	return setmetatable(events, egen_mt)
end

function eset_mt.__index:gen(def)
	local events = {}

	for _,e in pairs(def.events) do
		if self.ops[e.op.f] then
			table.insert(events, e)
		end
	end

	return egen(def, self.ops)
end

function egen_mt.__index:sub(match)
	local events = { N = self.N }

	for _,e in match_events(self, match) do
		table.insert(events, e)
	end

	return setmetatable(events, egen_mt)
end

function egen_mt.__index:branch(e)
	local mask = bitset.create(self.N)
	mask[e.i] = true
	
	return setmetatable({
		e,
		kind = e.event.kind,
		mask = mask,
		all_blocked_by = bitset.copy(e.blocked_by)
	}, branch_mt)
end

function egen_mt.__index:merge_branches()
	local have = bitset.create(self.N)
	local branches = {}

	for i=1, #self do
		local e = self[i]

		if have[e.i] then
			goto continue
		end

		have[e.i] = true

		if e.event.kind == "forced" then
			table.insert(branches, {event=e, kind="forced"})
			goto continue
		end

		local b = self:branch(e)
		table.insert(branches, b)

		for j=i+1, #self do
			local v = self[j]

			if (not have[v.i]) and b:can_merge(v) then
				for k=i+1, j do
					if v.after[self[k].i] then
						-- can't break temporal ordering
						goto skip
					end
				end

				b:merge(v)
				have[v.i] = true
			end

			::skip::
		end

		::continue::
	end

	return branches
end

function branch_mt.__index:can_merge(e)
	if e.event.kind == "forced" then return false end
	
	if not self.all_blocked_by[e.i] then return false end
	if not bitset.subset(self.mask, e.blocked_by) then return false end

	return true
end

function branch_mt.__index:merge(e)
	table.insert(self, e)

	self.mask[e.i] = true
	bitset.intersect(self.all_blocked_by, e.blocked_by)

	if e.event.kind == "semi-forced" then
		self.kind = "semi-forced"
	end
end

function branch_mt.__index:shared_block_time()
	local bt = self[1].event.block_time

	for i=2, #self do
		bt = math.min(bt, self[i].event.block_time)
	end

	return bt
end

-- TODO: to extend this to different block intervals per event pair, do
--     t_next_ok = max(past[id_1]+block_1, ..., past[id_N]+block_N)
local function latest(mask, tname)
	local v = {}

	for i in bitset.bits(mask) do
		table.insert(v, string.format("%s[%d]", tname, i))
	end

	assert(#v > 0)

	if #v > 1 then
		return string.format("max(%s)", table.concat(v, ", "))
	else
		return v[1]
	end
end

-- function(sim, past, t, continue, x, f)
--     local t_old = past[@id]
--
--     if not @check(past, t) then
--         goto skip
--     end
-- 
--     if @callback() == false then
--         return
--     end
--
--     past[@id] = t
-- 
--     ::skip::
--     @if tail
--         f(continue, x)
--     @else
--         @next(sim, past, t, continue, x, f, C.SIM_CREATE_SAVEPOINT)
--
--     past[@id] = t_old
-- end
function egen_mt.__index:compile_forced(e, f_next)
	local src = code.new()

	src:emit([[
		local _callback = _callback
		local _next = _next
		local max = math.max
		local C = ffi.C

		return function(sim, past, t, continue, x, f)
	]])

	src:emitf("local t_old = past[%d]", e.i)

	if bitset.any(e.blocked_by) then
		src:emitf([[
			if (t-%s) < %f then
				goto skip
			end
		]], latest(e.blocked_by, "past"), e.event.block_time)
	end

	if bitset.any(e.requires) then
		src:emitf([[
			if %s < t then
				goto skip
			end
		]], latest(e.requires, "past"))
	end

	src:emit([[
		if _callback() == false then
			return
		end
	]])

	src:emitf("past[%d] = t", e.i)

	src:emit("::skip::")
	if f_next then
		src:emit("_next(sim, past, t, continue, x, f, C.SIM_CREATE_SAVEPOINT)")
	else
		src:emit("f(continue, x)")
	end

	src:emitf("past[%d] = t_old", e.i)

	src:emit("end")

	return src:compile({_callback=e.f, _next=f_next, math=math, ffi=ffi},
		string.format("=(forced@%s)", e.event.name))()
end

-- function(sim, past, t, continue, x, f, flags)
--     if not @common_check(past, t) then
--         goto skip_all
--     end
--
--     sim:branch(flags)
--     local fp = sim:fp()
--
--     if not @check_1(past, t) then
--         goto skip_2
--     end
--
--     if sim:enter_branch(fp, 0) then
--         if @callback_1() ~= false then
--             local t_old = past[@id_1]
--             past[@id_1] = t
--
--             @if tail
--                 f(continue, x)
--             @else
--                 @next(sim, past, t, continue, x, f, C.SIM_CREATE_SAVEPOINT)
--
--             past[@id_1] = t_old
--         end
--     end
--
--     ::skip_2::
--     ...
--
--     ::skip_all::
--     @if semi-forced
--         return
--
--     if sim:enter_branch(fp, C.SIM_TAILCALL) then
--         @if tail
--             return f(continue, x)
--         @else
--             return @next(sim, past, t, continue, x, f, 0)
--     end
-- end
function egen_mt.__index:compile_optional(b, f_next)
	if b.kind == "semi-forced" then
		error("TODO")
	end

	local src = code.new()

	for i,e in ipairs(b) do
		src:emitf("local _callback_%d = events[%d].f", e.i, i)
	end

	src:emit([[
		local _next = _next
		local max = math.max
		local C = ffi.C

		return function(sim, past, t, continue, x, f, flags)
	]])

	local next_call = f_next
		and "_next(sim, past, t, continue, x, f, C.SIM_CREATE_SAVEPOINT)"
		or "f(continue, x)"
	local sbt = b:shared_block_time()

	if bitset.any(b.all_blocked_by) then
		src:emitf([[
			if (t-%s) < %f then
				goto skip_all
			end
		]], latest(b.all_blocked_by, "past"), sbt)
	end

	src:emit([[
		do
			sim:branch(flags)
			local fp = sim:fp()
			flags = 0
	]])

	for i,e in ipairs(b) do
		local next_label = i < #b and string.format("event_%d", i+1) or "skip_all"
		src:emitf("::event_%d::", i)

		if e.blocked_by ~= b.all_blocked_by or e.event.block_time > sbt then
			local blockers = e.blocked_by
			if e.event.block_time == sbt then
				blockers = e.blocked_by - b.all_blocked_by
			end

			src:emitf([[
				if (t-%s) < %f then
					goto %s
				end
			]], latest(blockers, "past"), e.event.block_time, next_label)
		end

		if bitset.any(e.requires) then
			src:emitf([[
				if %s < t then
					goto %s
				end
			]], latest(e.requires, "past"), next_label)
		end

		src:emitf([[
			if sim:enter_branch(fp, 0) then
				if _callback_%d() ~= false then
					local t_old = past[%d]
					past[%d] = t
					%s
					past[%d] = t_old
				end
			end
		]], e.i, e.i, e.i, next_call, e.i)
	end

	if f_next then
		next_call = "_next(sim, past, t, continue, x, f, flags)"
	end

	src:emitf([[
			if not sim:enter_branch(fp, C.SIM_TAILCALL) then
				return
			end
		end

		::skip_all::
		return %s
	end
	]], next_call)

	return src:compile({
		events = b,
		_next = f_next,
		math = math,
		ffi = ffi
	}, string.format("=(branch@%s+%d)", b[1].event.name, #b-1))()
end

function egen_mt.__index:compile_branch(b, f_next)
	if b.kind == "forced" then
		return self:compile_forced(b.event, f_next)
	else
		return self:compile_optional(b, f_next)
	end
end

function egen_mt.__index:compile()
	local branches = self:merge_branches()

	if #branches == 0 then
		return control.cont
	end

	local f = nil
	for i=#branches, 1, -1 do
		f = self:compile_branch(branches[i], f)
	end

	return f
end

function eset_mt.__index:compile(def, sim)
	local egen = self:gen(def)
	local past = ffi.new("float[?]", egen.N, -math.huge)

	for _,bf in ipairs(self.bfuncs) do
		local g = bf.match and egen:sub(bf.match) or egen
		local branch = g:compile()
		code.setupvalue(bf.call, "_branch", branch)
		code.setupvalue(bf.call, "_sim", sim)
		code.setupvalue(bf.call, "_past", past)
	end
end

---- public api ----------------------------------------

local function plan()
	return setmetatable({
		sets = {}
	}, plan_mt)
end

local function eset()
	return setmetatable({
		ops = {},
		bfuncs = {}
	}, eset_mt)
end

function plan_mt.__index:set()
	local set = eset()
	table.insert(self.sets, set)
	return set
end

function plan_mt.__index:finalize(def, sim)
	for _,s in ipairs(self.sets) do
		if #s.bfuncs > 0 then
			s:compile(def, sim)
		end
	end
end

function eset_mt.__index:provide(ops)
	for k,v in pairs(ops) do
		if self.ops[k] and self.ops[k] ~= v then
			error(string.format("Duplicate op '%s'", k))
		end
		self.ops[k] = v
	end

	return self
end

function eset_mt.__index:create(match)
	local set, call = load([[
		local SIM_CREATE_SAVEPOINT = require('ffi').C.SIM_CREATE_SAVEPOINT
		local _past, _t, _branch, _sim

		local function call(continue, x, f)
			return _branch(_sim, _past, _t, continue, x, f, SIM_CREATE_SAVEPOINT)
		end

		local function set(t)
			_t = t
			return call
		end

		return set, call
	]])()

	table.insert(self.bfuncs, {
		match = match,
		call = call
	})

	return set
end

return {
	create = plan
}
