local reflect = require "lib.reflect"
local ffi = require "ffi"
local C = ffi.C

local function lsb(x)
	return x ~= 0 and bit.band(x, -x) or nil
end

local typct = {
	[C.MT_SINT8]   = "int8_t",
	[C.MT_SINT16]  = "int16_t",
	[C.MT_SINT32]  = "int32_t",
	[C.MT_SINT64]  = "int64_t",
	[C.MT_UINT8]   = "uint8_t",
	[C.MT_UINT16]  = "uint16_t",
	[C.MT_UINT32]  = "uint32_t",
	[C.MT_UINT64]  = "uint64_t",
	[C.MT_FLOAT]   = "float",
	[C.MT_DOUBLE]  = "double",
	[C.MT_BOOL]    = "bool",
	[C.MT_POINTER] = "void *"
}

local typname = {
	[C.MT_SINT8]   = "i8",
	[C.MT_SINT16]  = "i16",
	[C.MT_SINT32]  = "i32",
	[C.MT_SINT64]  = "i64",
	[C.MT_UINT8]   = "u8",
	[C.MT_UINT16]  = "u16",
	[C.MT_UINT32]  = "u32",
	[C.MT_UINT64]  = "u64",
	[C.MT_FLOAT]   = "f",
	[C.MT_DOUBLE]  = "d",
	[C.MT_BOOL]    = "z",
	[C.MT_POINTER] = "p"
}

local function nameof(typeid)
	local name = typname[bit.band(typeid, bit.bnot(C.MT_SET))]
	if typeid >= C.MT_SET then name = name:upper() end
	return name
end

local typemask = ffi.typeof("struct { uint64_t mask; }")

ffi.metatype(typemask, {

	__index = {

		intersect = function(self, other)
			return typemask(bit.band(self.mask, ffi.istype(typemask, other) and other.mask or other))
		end,

		has = function(self, typ)
			return bit.band(self.mask, bit.lshift(1ULL, typ)) ~= 0
		end,

		isuniq = function(self)
			return self.mask == lsb(self.mask)
		end,

		uniq = function(self)
			local x = lsb(self.mask)
			if self.mask ~= x then return nil end

			-- no __builtin_ffsl here, so we bruteforce it.
			-- (this is better than a binary search, because binary search is super-branchy.
			-- a lookup table would be best but perf doesn't matter here anyway)
			for i=0, 63 do
				x = bit.rshift(x, 1)
				if x == 0 then
					return i
				end
			end

			assert(false)
		end

	},

	__add = function(self, other)
		return typemask(bit.bor(self.mask, ffi.istype(typemask, other) and other.mask or other))
	end,

	__tostring = function(self)
		if self.mask == bit.bnot(0ULL) then
			return "(any)"
		end

		local buf = {}
		for i=0, 63 do
			if bit.band(self.mask, bit.lshift(1ULL, i)) ~= 0 then
				table.insert(buf, nameof(i))
			end
		end

		return string.format("{%s}", table.concat(buf, ", "))
	end

})

ffi.metatype("struct mt_sig", {
	__tostring = function(self)
		local buf = {}
		for i=0, self.np-1 do
			table.insert(buf, nameof(self.typ[i]))
		end
		table.insert(buf, ">")
		for i=self.np, self.np+self.nr-1 do
			table.insert(buf, nameof(self.typ[i]))
		end
		return table.concat(buf, "")
	end,

	__eq = function(self, other)
		if self.np ~= other.np or self.nr ~= other.nr then
			return false
		end

		for i=0, self.np+self.nr-1 do
			if self.typ[i] ~= other.typ[i] then
				return false
			end
		end

		return true
	end
})

local masks = {
	any    = typemask(bit.bnot(0ULL)),
	set    = typemask(0xffffffff00000000ULL),
	scalar = typemask(0xffffffffULL)
}

local intoffset = { [1]=0, [2]=1, [4]=2, [8]=3 }

local function torefct(x)
	if type(x) == "string" then
		x = ffi.typeof(x)
	end

	if type(x) == "cdata" then
		x = reflect.typeof(x)
	end

	return type(x) == "table" and x or nil
end

local function fromctype(ct)
	ct = torefct(ct)

	if ct.what == "int" then
		if ct.bool and ct.size == 1 then return C.MT_BOOL end
		local base = ct.unsigned and C.MT_UINT8 or C.MT_SINT8
		return base + intoffset[ct.size]
	end

	if ct.what == "float" then
		return (ct.size == 4 and C.MT_FLOAT) or (ct.size == 8 and C.MT_DOUBLE)
	end

	if ct.what == "ptr" then
		return C.MT_POINTER
	end
end

local function sizeof(ty)
	return 2^(ty % 4)
end

-- type(x) = number       -> typemask(1 << mask)
--           ctype, refct -> typemask(ctype)
--           string       -> typemask(filter) or typemask(ctype)
--           uint64_t     -> typemask(mask)
--           nil          -> typemask(0xff...ff)
local function totypemask(x)
	if x == nil then
		return masks.any
	end

	if ffi.istype(typemask, x) then
		return x
	end

	if masks[x] then
		return masks[x]
	end

	if ffi.istype("uint64_t", x) then
		return typemask(x)
	end

	local ct = torefct(x)
	if ct then
		local mask = bit.lshift(1ULL, fromctype(x))
		return typemask(mask + bit.lshift(mask, 32)) -- include also set types
	end

	if type(x) == "number" then
		return typemask(bit.lshift(1ULL, x))
	end
end

local sigcst_mt = {
	__index = function(self, i)
		return self.tm
	end
}

local function sigmask(tm)
	tm = totypemask(tm)
	return {
		params = setmetatable({tm=tm}, sigcst_mt),
		returns = setmetatable({tm=tm}, sigcst_mt)
	}
end

return {

	typemask = totypemask,
	sigmask  = sigmask,

	sizeof = sizeof,
	nameof = nameof,

	ctypeof = function(ty)
		return ffi.typeof(typct[bit.band(ty, bit.bnot(C.MT_SET))])
	end,

	fromctype = fromctype,

	isset = function(typ)
		return bit.band(typ, C.MT_SET) ~= 0
	end,

	toset = function(ty)
		return bit.bor(ty, C.MT_SET)
	end

}
