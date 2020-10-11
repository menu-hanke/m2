local ffi = require "ffi"
local band, bor, bnot, lshift, rshift = bit.band, bit.bor, bit.bnot, bit.lshift, bit.rshift

local bs_ct = ffi.typeof [[
	struct {
		uint32_t size;
		uint32_t words[?];
	}
]]

local function set(bs, bit)
	bs.words[rshift(bit, 5)] = bor(bs.words[rshift(bit, 5)], lshift(1, band(bit, 0x1f)))
end

local function clear(bs, bit)
	bs.words[rshift(bit, 5)] = band(bs.words[rshift(bit, 5)], bnot(lshift(1, band(bit, 0x1f))))
end

local function nwords(size)
	return rshift(size+31, 5)
end

local function create(bits)
	local bs = ffi.new(bs_ct, nwords(bits))
	bs.size = bits
	return bs
end

local function checksize(bs, other)
	local nw, ow = nwords(bs.size), nwords(other.size)

	if nw ~= ow then
		error(string.format("size mismatch %d ~= %d", bs.size, other.size))
	end

	return nw
end

local function union(a, b, c)
	c = c or a
	assert(a.size == b.size and b.size == c.size)
	for i=0, nwords(a.size)-1 do
		a.words[i] = bor(b.words[i], c.words[i])
	end
	return a
end

local function intersect(a, b, c)
	c = c or a
	assert(a.size == b.size and b.size == c.size)
	for i=0, nwords(a.size)-1 do
		a.words[i] = band(b.words[i], c.words[i])
	end
	return a
end

local function difference(a, b, c)
	c = c or a
	assert(a.size == b.size and b.size == c.size)
	for i=0, nwords(a.size)-1 do
		a.words[i] = band(b.words[i], bnot(c.words[i]))
	end
	return a
end

local function cleartail(a)
	local lastword = nwords(a.size)
	local lastbit = band(a.size, 0x1f)
	a.words[lastword] = band(a.words[lastword], lshift(1, lasbit) - 1)
	return a
end

local function negate(a, b)
	b = b or a
	for i=0, nwords(a.size) do
		a.words[i] = bnot(b.words[i])
	end
	return cleartail(a)
end

local function subset(a, b)
	assert(a.size == b.size)
	for i=0, nwords(a.size)-1 do
		if band(a.words[i], b.words[i]) ~= a.words[i] then
			return false
		end
	end
	return true
end

local function any(a)
	for i=0, nwords(a.size)-1 do
		if a.words[i] ~= 0 then
			return true
		end
	end
	return false
end

local function copy(a, b)
	if not b then a, b = create(a.size), a end
	ffi.copy(a.words, b.words, 4*nwords(a.size))
	return a
end

-- not perf sensitive so w/e
-- a fast api would look like this:
--
--     x = next_set(a)
--     while x do
--         ...
--         x = next_set(a, x)
--     end
local function bits(a)
	return coroutine.wrap(function()
		for i=0, a.size-1 do
			if a[i] then
				coroutine.yield(i)
			end
		end
	end)
end

ffi.metatype(bs_ct, {
	__index = function(self, bit)
		-- words[bit/32] & (1 << (bit%32))
		return bit < self.size and band(self.words[rshift(bit, 5)], lshift(1, band(bit, 0x1f))) ~= 0
	end,

	__newindex = function(self, bit, value)
		if bit >= self.size then
			error(string.format("index oob %d >= %d", bit, self.size))
		end

		if value then
			set(self, bit)
		else
			clear(self, bit)
		end
	end,

	__add = function(self, other) return union(create(self.size), self, other) end,
	__mul = function(self, other) return intersect(create(self.size), self, other) end,
	__sub = function(self, other) return difference(create(self.size), self, other) end,
	__unm = function(self) return negate(create(self.size), self) end,

	__eq = function(self, other)
		assert(self.size == other.size)
		for i=0, nwords(self.size)-1 do
			if self.words[i] ~= other.words[i] then
				return false
			end
		end

		return true
	end
})

return {
	create = create,
	set = set,
	clear = clear,
	union = union,
	intersect = intersect,
	difference = difference,
	negate = negate,
	subset = subset,
	any = any,
	copy = copy,
	bits = bits
}
