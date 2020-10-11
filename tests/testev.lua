local ffi = require "ffi"
local event = require "event"
local misc = require "misc"

local rec_mt = {
	__call = function(self, x)
		self.ptr[0] = self.ptr[0] + 1
		self[self.ptr[0]] = x
	end,

	__tostring = function(self)
		if self.ptr[0] == 0 then
			return "_"
		end

		local s = {}
		for i=1, self.ptr[0] do
			table.insert(s, self[i])
		end
		return table.concat(s, self.sep)
	end
}

local function rec(ptr, sep)
	return setmetatable({ptr=ptr, sep=sep or ""}, rec_mt)
end

local count_mt = {
	__call = function(self, x)
		x = tostring(x)
		self[x] = (self[x] or 0) + 1
	end
}

local function count()
	return setmetatable({}, count_mt)
end

local function assert_same(a, b)
	for i=1, 2 do
		for k,v in pairs(a) do
			if b[k] ~= v then
				error(string.format("%s: %s ~= %s", k, v, b[k]))
			end
		end

		a,b = b,a
	end
end

local tdef_mt = { __index={} }

local function tdef(m2)
	local ptr = m2.new(ffi.typeof"int", "vstack")
	ptr[0] = 0
	local rec = rec(ptr)

	local count = count()
	m2.on("test-events#100", function() count(rec) end)

	return setmetatable({
		m2     = m2,
		branch = m2.events():provide({
			call = function(x) return function() rec(x) end end,
			always_fails = function() return function() return false end end
		}):create(),
		rec    = rec,
		count  = count
	}, tdef_mt)
end

function tdef_mt.__index:steps(steps)
	for _,s in ipairs(steps) do
		self.m2.on("test-events", type(s) == "function" and s or function()
			return self.branch(s)
		end)
	end
end

function tdef_mt.__index:inject(env)
	env.paths = function(paths) self.paths = paths end
	env.steps = misc.delegate(self, self.steps)
	env.compile_fails = function() self.compile_fails = true end
end

function tdef_mt.__index:assert_hypothesis(env)
	if self.compile_fails then
		assert(not pcall(function() env:prepare() end))
		return
	end

	env:prepare()
	env:event("test-events")

	if self.paths then
		assert_same(self.paths, self.count)
	end
end

return {
	test_def = tdef
}
