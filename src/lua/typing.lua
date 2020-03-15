local aux = require "aux"
local ffi = require "ffi"
local C = ffi.C

--------------------------------------------------------------------------------
-- tvalue/pvalue: see type.h/type.c - these unions are used for communicating with the "outside"
-- world (ie. fhk-related). the lifecycle of a tvalue:
-- * when fhk reads a tvalue it's promoted tvalue->pvalue (vpromote)
--   pvalue is the internal representation fhk uses
-- * when fhk passes the pvalue into a model it's exported (vexportd)
-- * when the model returns a value it's imported into a pvalue (vimportd)
-- * NOTE: fhk DOES NOT automatically demote the results (TODO - the iterating solver probably
--   should solve the pvalues in a scratch buffer and then vdemote each scratch buffer -
--   this can be done in place even)

local tvalue_mt = { __index = {} }

local function tval(name, desc, ctype)
	return setmetatable({name=name, desc=desc, ctype=ffi.typeof(ctype)}, tvalue_mt)
end

-- see enum type
local tvalues = {
	f32 = tval("f32",         C.T_F32,      "float"),
	f64 = tval("f64",         C.T_F64,      "double"),

	u8  = tval("u8",          C.T_U8,       "uint8_t"),
	u16 = tval("u16",         C.T_U16,      "uint16_t"),
	u32 = tval("u32",         C.T_U32,      "uint32_t"),
	u64 = tval("u64",         C.T_U64,      "uint64_t"),

	-- these are also uint*_t, like the u* types, but have different semantics:
	-- fhk will pack/unpack the bitmask when passing to models
	b8  = tval("u8",          C.T_B8,       "uint8_t"),
	b16 = tval("u16",         C.T_B16,      "uint16_t"),
	b32 = tval("u32",         C.T_B32,      "uint32_t"),
	b64 = tval("u64",         C.T_B64,      "uint64_t"),

	z   = tval("z",           C.T_POSITION, "gridpos"),
	u   = tval("u",           C.T_USERDATA, "void *")
}

local pvalues = {
	real     = tvalues.f64,
	mask     = tvalues.b64,
	id       = tvalues.u64,
	position = tvalues.z,
	udata    = tvalues.u
}

local function tvalue_from_desc(desc)
	for _,t in pairs(tvalues) do
		if t.desc == desc then
			return t
		end
	end

	error(string.format("No tvalue matching desc 0x%x", desc))
end

-- see type.h (this is the TYPE_PROMOTE macro)
local function promote(t)
	return bit.bor(t, 3)
end

local function demote(t, s)
	assert(s == 1 or s == 2 or s == 4 or s == 8)
	return bit.band(t, bit.bnot(3)) + math.log(s, 2)
end

function tvalue_mt.__index:promote()
	return tvalue_from_desc(promote(self.desc))
end

function tvalue_mt.__index:demote(s)
	return tvalue_from_desc(demote(self.desc, s))
end

--------------------------------------------------------------------------------
-- newtype/typedefs: this exists to help generate cdata structs for the sim datatypes
-- (see soa.lua, ns.lua). It's a recursive structure and contains the fields:
-- * vars   - you can write to this BEFORE generating the ctype, after that it's frozen.
--            this should be a map name => type
-- * fields - readonly list of field names. this is sorted to ensure generating the same struct
--            each run
-- * ctype  - readonly luajit ctype for this type

local typedef_f = {}
local typedef_mt = { __index = aux.lazy(typedef_f) }
local frozen_mt = {}

local function ctype(ct)
	return {ctype=ffi.typeof(ct)}
end

local function newtype(vars)
	return setmetatable({vars = vars}, typedef_mt)
end

local totype

-- flatten nested arrays and allow ctypes and aliases to be given as strings
-- (allows for cleaner syntax when specifying types)
local function normalize_vars(normalized, vars)
	for name,v in pairs(vars) do
		if type(name) == "number" then -- nested table
			normalize_vars(normalized, v)
		elseif type(v) == "string" then -- alias or ctype
			normalized[name] = pvalues[v] or tvalues[v] or ctype(v)
		elseif type(v) == "cdata" then
			normalized[name] = ctype(v)
		else -- typedef
			normalized[name] = totype(v)
		end
	end

	return normalized
end

totype = function(vars)
	if getmetatable(vars) == typedef_mt or vars.ctype then
		return vars
	end

	return newtype(normalize_vars({}, vars))
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

	local members = {}
	local ctypes = {}

	for i,f in ipairs(fields) do
		members[i] = string.format("$ %s;", f)
		ctypes[i] = self.vars[f].ctype
	end

	return ffi.typeof(string.format("struct { %s }", table.concat(members, " ")), unpack(ctypes))
end

local function yield_offsets(t, off)
	for i,f in ipairs(t.fields) do
		local vi = t.vars[f]
		local offset = off + ffi.offsetof(t.ctype, f)

		if vi.vars then
			yield_offsets(vi, offset)
		else
			coroutine.yield(f, offset, ffi.sizeof(vi.ctype))
		end
	end
end

-- helper function for fhk mappings: iterate recursively through each var offset
-- in the generated struct
local function offsets(t)
	return coroutine.wrap(function()
		if not t.vars then return end
		yield_offsets(t, 0)
	end)
end

--------------------------------------------------------------------------------

-- classifications: these are like enums in C, but values are always 2^m (1 bit set),
-- so membership tests can be done fast with bit operations
local class_mt = {
	__newindex = function(self, name, m)
		if m < 0 or m >= 64 then
			error(string.format("Class value out of range: %d", m))
		end

		rawset(self, name, C.vbpack(m))
	end
}

local function class(values)
	local cls = setmetatable({}, class_mt)
	if values then
		for name,m in pairs(values) do
			cls[name] = m
		end
	end
	return cls
end

local function fitclass(cls)
	local M = 0

	for _,v in pairs(cls) do
		M = math.max(M, v)
	end

	M = C.vbunpack(M)
	local bytes = 8*math.ceil(M/8)
	return tvalues[string.format("b%d", bytes)]
end

--------------------------------------------------------------------------------

-- returns (typ) &t.name
-- (void* by default, i don't think there's any good way to recover the type of t.name)
local function memb_ptr(ct, name, x, typ)
	return ffi.cast(typ or "void *", ffi.cast("char *", x or 0) + ffi.offsetof(ct, name))
end

-- build types, mostly useful for testing
local function reals(...)
	local t = newtype({})
	for _,name in ipairs({...}) do
		t.vars[name] = pvalues.real
	end
	return t
end

local function inject(env)
	aux.merge(env.m2, {
		import_enum = C.vbpack,
		import_bool = function(v) return v and 1 or 0 end,
		export_enum = C.vbunpack,
		export_bool = function(v) return v ~= 0 end,
		type        = totype
	})
end

return {
	tvalues       = tvalues,
	pvalues       = pvalues,
	promote       = promote,
	demote        = demote,

	ctype         = ctype,
	newtype       = newtype,
	totype        = totype,
	yield_offsets = yield_offsets,
	offsets       = offsets,

	class         = class,
	fitclass      = fitclass,

	memb_ptr      = memb_ptr,
	reals         = reals,

	inject        = inject
}
