require "fhk.ctypes"
local code = require "code"
local ffi = require "ffi"
local C = ffi.C

local stgen_mt = { __index={} }
local dvgen_mt = { __index={} }

local function shapetablegen()
	return setmetatable({ }, stgen_mt)
end

function stgen_mt.__index:shape(group, shapef)
	self[group] = shapef
end

function stgen_mt.__index:compile()
	local st = code.new()

	local ng = #self+1 -- groups are zero indexed

	for i=0, #self do
		st:emitf("local group%d_shapef = shapef[%d]", i, i)
	end

	st:emitf([[
		local ffi = ffi
		local C = ffi.C
		
		return function(state, arena)
			local shape = ffi.cast("int16_t *", C.arena_alloc(arena, %d, 2))
	]], 2*ng)

	for i=0, #self do
		-- TODO: specialize for constants
		st:emitf("shape[%d] = group%d_shapef(state)", i, i)
	end

	st:emit([[
			return shape
		end
	]])

	return st:compile({ffi=ffi, shapef=self}, string.format("=(shapetable@%p)", self))()
end

local function drivergen()
	return setmetatable({
		inits        = {},
		virt         = {},
		udata_offset = 0
	}, dvgen_mt)
end

function dvgen_mt.__index:reserve(ctype)
	local offset = self.udata_offset
	self.udata_offset = self.udata_offset + ffi.sizeof(ctype)
	return {offset=offset, ctype=ctype}
end

function dvgen_mt.__index:init(f, ...)
	table.insert(self.inits, {f=f, ud={...}})
end

function dvgen_mt.__index:virtual(f)
	local handle = #self.virt+1
	self.virt[handle] = f
	return handle
end

local function driver_loop(virt)
	return function(solver, udata, arena)
		while true do
			local cr = C.fhkD_continue(solver, udata, arena)

			if cr == ffi.NULL then
				return
			end

			if cr.status == C.FHK_ERROR then
				-- TODO error message
				error("Driver failed")
			end

			virt[cr.handle](cr, solver, arena)
		end
	end
end

function dvgen_mt.__index:compile()
	local caller = code.new()

	caller:emit([[
		local ffi = ffi
		local C = ffi.C
		local driver = driver
	]])

	for i,f in ipairs(self.inits) do
		caller:emitf("local init%d_f = inits[%d].f", i, i)
		for j,_ in ipairs(f.ud) do
			caller:emitf("local init%d_ct%d = ffi.typeof('$ *', inits[%d].ud[%d].ctype)", i, j, i, j)
		end
	end

	caller:emitf([[
		return function(state, solver, arena)
			local udata = ffi.cast("uint8_t *", C.arena_malloc(arena, %d))
	]], self.udata_offset)

	for i,f in ipairs(self.inits) do
		local args = { "state", "arena" }
		for j,u in ipairs(f.ud) do
			table.insert(args, string.format("ffi.cast(init%d_ct%d, udata+%d)", i, j, u.offset))
		end
		caller:emitf("init%d_f(%s)", i, table.concat(args, ", "))
	end

	caller:emit("driver(solver, udata, arena)")
	caller:emit("end")

	return caller:compile({
		ffi    = ffi,
		inits  = self.inits,
		driver = driver_loop(self.virt)
	}, string.format("=(driver@%p)", self))()
end

local function ccall(cs, ud)
	ud = ud and ud.offset or 0
	assert(ud <= 0xffff)
	return ffi.new("fhk_arg", {u64 = ffi.cast("uintptr_t", cs) + bit.lshift(ud, 48ULL)})
end

local function luacall(handle, handle2)
	return 1 + bit.lshift(handle, 16ULL) + (handle2 and bit.lshift(handle2, 32ULL) or 0)
end

local function mcall(alloc, model, gsig, msig)
	local udata = ffi.cast("struct fhkD_cmodel *", alloc(
		ffi.sizeof("struct fhkD_cmodel"),
		ffi.alignof("struct fhkD_cmodel")
	))

	udata.model = model
	udata.fp    = model.call
	udata.gsig  = gsig
	udata.msig  = msig

	return ffi.new("fhk_arg", {p=udata})
end

-- see comment in driver.h
local function refk(kp, offset)
	return ffi.new("fhk_arg", {u64 =
		0x2
		+ bit.lshift(offset or 0x3fff, 2ULL)
		+ bit.lshift(ffi.cast("uintptr_t", kp), 16ULL)
	})
end

-- see comment in driver.h
local function refx(ud, off1, off2, off3)
	return ffi.new("fhk_arg", {u64 =
		0x3
		+ bit.lshift(ud.offset, 2ULL)
		+ (off1 and (0x80000000ULL         + bit.lshift(off1, 16ULL)) or 0)
		+ (off2 and (0x800000000000ULL     + bit.lshift(off2, 32ULL)) or 0)
		+ (off3 and (0x8000000000000000ULL + bit.lshift(off3, 48ULL)) or 0)
	})
end

local function luavar(f)
	-- you must call the fhkS_* function you want inside the callback
	return function(cr, solver, arena)
		f(cr.xi, cr.instance, solver, arena)
	end
end

local function luamap_w(f)
	-- you must return an fhk_subset
	return function(cr, solver, arena)
		cr.ss[0] = f(cr.instance, solver, arena)
	end
end

local function luamap(fm, fi)
	return luamap_w(fm), luamap_w(fi)
end

return {
	gen           = drivergen,
	shapetablegen = shapetablegen,
	ccall         = ccall,
	luacall       = luacall,
	mcall         = mcall,
	refk          = refk,
	refx          = refx
}
