local ffi = require "ffi"
local C = ffi.C

local typedef_f = {}
local typedef_mt = { __index=lazy(typedef_f) }
local frozen_mt = {}

local builtin_types = {
--  Lua name | tvalue name | enum type        | C data type
	real32 = { tname="f32",  desc=C.T_F32,      ctype="float" },
	real   = { tname="f64",  desc=C.T_F64,      ctype="double" },
	bit8   = { tname="u8",   desc=C.T_B8,       ctype="uint8_t" },
	bit16  = { tname="u16",  desc=C.T_B16,      ctype="uint16_t" },
	bit32  = { tname="u32",  desc=C.T_B32,      ctype="uint32_t" },
	bit64  = { tname="u64",  desc=C.T_B64,      ctype="uint64_t" },
	id     = { tname="u64",  desc=C.T_ID,       ctype="uint64_t" },
	z      = { tname="z",    desc=C.T_POSITION, ctype="gridpos" },
	udata  = { tname="u",    desc=C.T_USERDATA, ctype="void *" }
}

local desc_ctype = {}

for _,v in pairs(builtin_types) do
	setmetatable(v, typedef_mt)
	desc_ctype[tonumber(v.desc)] = v.ctype
end

local function newtype(name)
	return setmetatable({plain_name=name, vars={}}, typedef_mt)
end

local function ctype(name)
	return {ctype=name}
end

function frozen_mt:__newindex()
	error("Can't modify type after generating ctype")
end

function typedef_f:fields()
	setmetatable(self.vars, frozen_mt)

	local fields = {}
	for k,_ in pairs(self.vars) do
		table.insert(fields, k)
	end

	-- this is to have a consistent ordering across runs
	table.sort(fields)

	return fields
end

function typedef_f:ctype()
	local fields = self.fields
	local fields_cdef = {}
	for i,f in ipairs(fields) do
		fields_cdef[i] = string.format("%s %s;", self.vars[f].ctype, f)
	end
	local ctname = string.format("struct Lgen__%s__", self.plain_name)
	local cdef = string.format("%s { %s };", ctname, table.concat(fields_cdef, " "))
	--print(cdef)
	ffi.cdef(cdef)

	return ctname
end

local function offsetof(t, f)
	return ffi.offsetof(t.ctype, f)
end

--------------------------------------------------------------------------------

local enum_f = {}
local enum_mt = { __index = lazy(enum_f) }
local enum_values_mt = {}

local function newenum()
	return setmetatable({ values=setmetatable({}, enum_values_mt) }, enum_mt)
end

function enum_values_mt:__newindex(k, v)
	rawset(self, k, C.vbpack(v))
end

local function bit_min(bits)
	local bytes = 8*math.ceil(bits/8)
	return bytes <= 64 and builtin_types["bit"..bytes]
end

function enum_f:_builtin()
	local maxv = 1

	for _,i in pairs(self.values) do
		if i > maxv then
			maxv = i
		end
	end

	setmetatable(self.values, frozen_mt)
	maxv = C.vbunpack(maxv)
	return bit_min(maxv)
end

function enum_f:ctype()
	return self._builtin.ctype
end

function enum_f:desc()
	return self._builtin.desc
end

--------------------------------------------------------------------------------

local tvalue = setmetatable({}, { __index = function(_, k)
	return function(v)
		local ret = ffi.new("tvalue")
		ret[k] = v
		return ret
	end
end})

-- see type.h
local function promote(t)
	return bit.bor(t, 3)
end

local function mask(bits)
	local ret = 0ULL

	for _,v in ipairs(bits) do
		if v<0 or v>63 then
			error(string.format("invalid bit: %d", v))
		end

		ret = bit.bor(ret, C.vbpack(v))
	end

	return ret
end

return {
	builtin_types = builtin_types,
	desc_ctype    = desc_ctype,
	newtype       = newtype,
	offsetof      = offsetof,
	ctype         = ctype,
	newenum       = newenum,
	enumct        = enumct,
	tvalue        = tvalue,
	promote       = promote,
	mask          = mask
}
