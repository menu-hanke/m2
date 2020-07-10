local code = require "code"

local chain_mt = { __index = {} }
local def_mt = { __index = {} }

local function create_chain(name)
	return setmetatable({name=name}, chain_mt)
end

function chain_mt.__index:add(f, prio)
	table.insert(self, {f=f, prio=prio, order=#self})
end

function chain_mt.__index:sort()
	-- table.sort isn't stable so we have to make it stable to preserve chain order across runs
	table.sort(self, function(a, b)
		if a.prio ~= b.prio then return a.prio < b.prio end
		return a.order < b.order
	end)
end

-- Generates roughly:
--
--     local f1, ..., fN = chain[1].f, ..., chain[N].f
--
--     local function _fNminus1(x)
--         local branch = fNminus1(x)
--         if branch then return branch, fN end
--         return fN(x)
--     end
--
--     ...
--
--     local function _f1(x)
--         local branch = f1(x)
--         if branch then return branch, _f2 end
--         return _f2(x)
--     end
--
--     return _f1
function chain_mt.__index:compile()
	if #self == 0 then return function() end end
	if #self == 1 then return self[1].f end

	self:sort()

	local out = code.new()
	for i=1, #self-1 do
		out:emitf("local f%d = chain[%d].f", i, i)
	end
	out:emitf("local _f%d = chain[%d].f", #self, #self)

	for i=#self-1, 1, -1 do
		out:emitf([[
			local function _f%d(x)
				local _b = f%d(x)
				if _b then return _b, _f%d end
				return _f%d(x)
			end
		]], i, i, i+1, i+1)
	end

	out:emit("return _f1")

	return out:compile({chain=self}, string.format("=(chain@%s)", self.name))()
end

local function def()
	return setmetatable({ chains={} }, def_mt)
end

function def_mt.__index:compile()
	local chains = {}

	for event,chain in pairs(self.chains) do
		chains[event] = chain:compile()
	end

	return chains
end

function def_mt.__index:on(event, f, prio)
	if not prio then
		local e, p = event:match("([^#]*)#?([%-%+]?%d*)")
		event = e
		prio = tonumber(p)
	end

	if not self.chains[event] then
		self.chains[event] = create_chain(event)
	end

	self.chains[event]:add(f, prio or 0)
end

local function record()
	local insn = {}
	return setmetatable({}, {
		__index = function(_, f)
			return function(x)
				table.insert(insn, {f=f, arg=x})
			end
		end,

		insn = insn
	})
end

local function getrecord(r)
	return getmetatable(r).insn
end

-- Roughly same logic as chain compilation. Generates for example:
--
--     local chain1, ..., chainN = chains[insn[1].f], ..., chains[insn[N].f]
--     local x1, ..., xN = insn[1].arg, ..., insn[N].arg
--
--     local function stepN()
--         local _b, _e = chainN(xN)
--         if _b then return _b, _e, xN, function() end end
--     end
--
--     local function stepNminus1()
--         local _b, _e = chainNminus1(xNminus1)
--         if _b then return _b, _e, xNminus1, stepN end
--         return stepN()
--     end
--
--     ...
--
--     local function step1()
--         local _b, _e = chain1(x1)
--         if _b then return _b, _e, x1, step2 end
--         return step2()
--     end
--
--     return step1
local function compile_insn(insn, chains)
	local have = {}
	for i, v in ipairs(insn) do
		if chains[v.f] then
			table.insert(have, v)
		end
	end

	if #have == 0 then return function() end end

	local out = code.new()

	for i, v in ipairs(have) do
		out:emitf("local chain%d, x%d = chains[insn[%d].f], insn[%d].arg", i, i, i, i)
	end

	out:emitf([[
		local function nop() end

		local function step%d()
			local _b, _e = chain%d(x%d)
			if _b then return _b, _e, x%d, nop end
		end
	]], #have, #have, #have, #have)

	for i=#have-1, 1, -1 do
		out:emitf([[
			local function step%d()
				local _b, _e = chain%d(x%d)
				if _b then return _b, _e, x%d, step%d end
				return step%d()
			end
		]], i, i, i, i, i+1, i+1)
	end

	out:emit("return step1")

	return out:compile({insn=have, chains=chains}, string.format("=(insn@%p+%p)", insn, chains))()
end

local function continue(e, x, s)
	if e then
		local b, e, x, s = e(x)
		if b then
			return b(e, x, s)
		end
	end

	local b, e, x, s = s()
	if b then
		return b(e, x, s)
	end
end

local function exec(insn)
	continue(nil, nil, insn)
end

local function event(chains, name, ...)
	if chains[name] then
		local b, e = chains[name](...)
		if b then
			error(string.format("No branching allowed here (chain %s)", name))
		end
	end
end

local function inject(env)
	env.m2.record = record
end

return {
	def         = def,
	instruction = function(rec, chains) return compile_insn(getrecord(rec), chains) end,
	continue    = continue,
	exec        = exec,
	event       = event,
	inject      = inject
}
