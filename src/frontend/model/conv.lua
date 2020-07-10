local reflect = require "lib.reflect"
local ffi = require "ffi"
local C = ffi.C

local function lsb(x)
	return x ~= 0 and bit.band(x, -x) or nil
end

-- must match conv.h
local typname = {
	[0] = "u8", "u16", "u32", "u64",
	"i8", "i16", "i32", "i64",
	"m8", "m16", "m32", "m64",
	"f", "d",
	"z",
	"p"
}

local function nameof(typeid)
	local set = false
	if typeid >= C.MT_SET then
		set = true
		typeid = typeid - C.MT_SET
	end

	local name = typname[typeid]
	if set and name then name = name:upper() end
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
	end
})

local function sigmask(sig)
	return typemask(C.mt_sig_mask(sig))
end

local masks = {
	any    = typemask(bit.bnot(0ULL)),
	set    = typemask(0xffffffff00000000ULL),
	single = typemask(0xffffffffULL),
	mask8  = sigmask "m8M8",
	mask16 = sigmask "m16M16",
	mask32 = sigmask "m32M32",
	mask64 = sigmask "m64M64",
	mask   = sigmask "m8m16m32m64M8M16M32M64"
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

return {

	-- type(x) = number       -> typemask(1 << mask)
	--           ctype, refct -> typemask(ctype)
	--           string       -> typemask(filter) or typemask(ctype)
	--           uint64_t     -> typemask(mask)
	--           nil          -> typemask(0xff...ff)
	typemask = function(x)
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
	end,

	set_typemask = function(isset)
		return isset and set_typemask or singleton_typemask
	end,

	sizeof = function(typ)
		return tonumber(C.mt_sizeof(typ))
	end,

	fromctype = fromctype,

	ctypeof = function(ty)
		local ct

		ty = bit.band(ty, bit.bnot(C.MT_SET))
		if ty <= C.MT_UINT64 or (ty >= C.MT_MASK8 and ty <= C.MT_MASK64) then
			ct = string.format("uint%d_t", 8*tonumber(C.mt_sizeof(ty)))
		elseif ty <= C.MT_SINT64 then
			ct = string.format("int%d_t", 8*tonumber(C.mt_sizeof(ty)))
		elseif ty == C.MT_FLOAT then
			ct = "float"
		elseif ty == C.MT_DOUBLE then
			ct = "double"
		elseif ty == C.MT_BOOL then
			ct = "bool"
		elseif ty == C.MT_POINTER then
			ct = "void *"
		end

		return ffi.typeof(ct)
	end,

	isset = function(typ)
		return bit.band(typ, C.MT_SET) ~= 0
	end,

	toset = function(ty)
		return bit.bor(ty, C.MT_SET)
	end,

	nameof = nameof
}
