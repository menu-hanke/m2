local code = require "code"

local kernel_mt = { __index={} }

local function create(loop)
	return setmetatable({
		signature = loop.signature,
		fend      = loop.fend or "end",
		header    = loop.header,
		lend      = loop.lend or "end",
		value     = loop.init or "nil",
		code      = code.new(),
		upvalues  = {},
	}, kernel_mt)
end

function kernel_mt.__index:map(f)
	local name = "___map"..#self.code
	self.code:emitf("local %s = %s", name, name)
	self.upvalues[name] = f
	self.value = string.format("%s(%s)", name, self.value)
	return self
end

function kernel_mt.__index:reduce(f, ...)
	local name = "___reduce"..#self.code
	self.code:emitf("local %s = %s", name, name)
	self.upvalues[name] = f

	local init = {...}
	for i,v in ipairs(init) do
		local ivname = "___reduce_init"..i
		self.code:emitf("local %s = %s", ivname, ivname)
		self.upvalues[ivname] = v
	end

	self:enter_function()

	local rvs = {}
	for i,v in ipairs(init) do
		table.insert(rvs, "___r"..i)
		self.code:emitf("local ___r%d = ___reduce_init%d", i, i)
	end

	self:enter_loop()
	rvs = table.concat(rvs, ", ")
	self.code:emitf("%s = %s(%s, %s)", rvs, name, rvs, self.value)
	self:exit_loop()

	self.code:emitf("return %s", rvs)
	self:exit_function()

	return self:compile()
end

function kernel_mt.__index:sum()
	return self:reduce(function(a, b) return a+b end, 0)
end

function kernel_mt.__index:dot2()
	return self:reduce(function(r, a, b) return r+a*b end, 0)
end

function kernel_mt.__index:compile()
	return self.code:compile(self.upvalues, "=(kernel)")()
end

function kernel_mt.__index:enter_function()
	self.code:emit(self.signature)
end

function kernel_mt.__index:enter_loop()
	self.code:emit(self.header)
end

function kernel_mt.__index:exit_loop()
	self.code:emit(self.lend)
end

function kernel_mt.__index:exit_function()
	self.code:emit(self.fend)
end

local function inject(env)
	env.m2.kernel = {}
end

return {
	inject = inject,
	create = create
}
