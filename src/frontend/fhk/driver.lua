require "fhk.ctypes"
local code = require "code"
local model = require "model"
local ctypes = require "fhk.ctypes"
local ffi = require "ffi"
local C = ffi.C

local fhkD_status = ffi.metatype("fhkD_status", {
	__index = {
		fmt_error = function(self, ecode, syms)
			if ecode == C.FHKDE_CONV then return "type conversion error" end
			if ecode == C.FHKDE_MOD then
				return string.format("model call error (%d): %s", self.e_mstatus, model.error())
			end
			if ecode == C.FHKDE_FHK then
				return string.format("fhk failed: %s", ctypes.fmt_error(
					ctypes.status_arg(self.e_status).s_ei, syms))
			end

			assert(false)
		end
	}
})

local fhkD_status_p = ffi.typeof("fhkD_status *")

local dvgen_mt = { __index={} }

local function compile_shapeinit(shapefs)
	if not shapefs[0] then
		return function() end
	end

	local out = code.new()
	local ng = #shapefs+1 -- 0-indexed

	for i=0, ng-1 do
		out:emitf("local group%d_shapef = shapefs[%d]", i, i)
	end

	out:emitf([[
		local ffi = ffi
		local C = ffi.C

		return function(state, arena)
			local shape = ffi.cast("int16_t *", C.arena_alloc(arena, %d, %d))
	]], ng*ffi.sizeof("fhk_idx"), ffi.alignof("fhk_idx"))

	for i=0, ng-1 do
		out:emitf("shape[%d] = group%d_shapef(state)", i, i)
	end

	out:emit([[
			return shape
		end
	]])

	return out:compile({ffi=ffi, shapefs=shapefs}, string.format("=(shapeinit@%p)", shapefs))()
end

local function drivergen()
	return setmetatable({
		inits        = {},
		udata_offset = 0,
		udata_align  = 1
	}, dvgen_mt)
end

function dvgen_mt.__index:reserve(ctype)
	local offset = self.udata_offset
	offset = offset + (-offset%ffi.alignof(ctype))
	self.udata_offset = offset + ffi.sizeof(ctype)
	self.udata_align = math.max(self.udata_align, ffi.alignof(ctype))
	return {offset=offset, ctype=ctype}
end

function dvgen_mt.__index:init(f, ...)
	table.insert(self.inits, {f=f, ud={...}})
end

local function create_driver(D, syms)
	return function(solver, umem, arena)
		local status = ffi.cast(fhkD_status_p, C.arena_alloc(arena,
			ffi.sizeof(fhkD_status), ffi.alignof(fhkD_status)))

		while true do
			local s = C.fhkD_continue(solver, D, status, arena, umem)

			if s == C.FHKD_OK then
				return
			end

			if s < 0 then
				return status:fmt_error(s, syms)
			end

			-- TODO: FHKDL_* virtuals
			assert(false)
		end
	end
end

function dvgen_mt.__index:compile(D, syms)
	local caller = code.new()

	caller:emit([[
		local ffi = ffi
		local C = ffi.C
		local driver = driver
		local cast = ffi.cast
		local uint8_p = ffi.typeof "uint8_t *"
	]])

	for i,f in ipairs(self.inits) do
		caller:emitf("local init%d_f = inits[%d].f", i, i)
		for j,_ in ipairs(f.ud) do
			caller:emitf("local init%d_ct%d = ffi.typeof('$ *', inits[%d].ud[%d].ctype)", i, j, i, j)
		end
	end

	caller:emit("return function(state, solver, arena)")
	if self.udata_offset > 0 then
		caller:emitf("local udata = cast(uint8_p, C.arena_alloc(arena, %d, %d))",
			self.udata_offset, self.udata_align)
	else
		caller:emit("local udata = nil")
	end

	for i,f in ipairs(self.inits) do
		local args = { "state", "arena" }
		for j,u in ipairs(f.ud) do
			table.insert(args, string.format("cast(init%d_ct%d, udata+%d)", i, j, u.offset))
		end
		caller:emitf("init%d_f(%s)", i, table.concat(args, ", "))
	end

	caller:emit("return driver(solver, udata, arena)")
	caller:emit("end")

	return caller:compile({
		ffi    = ffi,
		inits  = self.inits,
		driver = create_driver(D, syms)
	}, string.format("=(driver@%p)", self))()
end

local function mcall_conv(gsig, msig, alloc)
	local convs = {}

	for i=0, gsig.np-1 do
		if gsig.typ[i] ~= msig.typ[i] then
			table.insert(convs, {ei=i, from=gsig.typ[i], to=msig.typ[i]})
		end
	end

	local np = #convs

	for i=gsig.np, gsig.np+gsig.nr-1 do
		if gsig.typ[i] ~= msig.typ[i] then
			table.insert(convs, {ei=i, from=msig.typ[i], to=gsig.typ[i]})
		end
	end

	local n = #convs

	local mconv = ffi.cast("fhkD_conv *",
		alloc(n * ffi.sizeof("fhkD_conv"), ffi.alignof("fhkD_conv")))
	
	for i,c in ipairs(convs) do
		mconv[i-1].ei = c.ei
		mconv[i-1].from = c.from
		mconv[i-1].to = c.to
	end

	return mconv, np, n
end

---- models calls ----------------------------------------

local function mcall(dm, model, conv, np, n)
	dm.tag = C.FHKDM_MCALL
	dm.m_npconv = np
	dm.m_nconv = n
	dm.m_conv = conv
	dm.m_fp = model.call
	dm.m_model = model
	return dm
end

ffi.metatype("fhkD_model", {
	__index = {
		set_mcall = mcall
	}
})

---- vars ----------------------------------------

local function vref(dv, ...)
	local offsets = {...}
	dv.r_num = #offsets
	for i, o in ipairs(offsets) do
		dv.r_off[i-1] = o
	end
	return dv
end

local function vrefk(dv, p, ...)
	dv.tag = C.FHKDV_REFK
	dv.rk_ref = p
	return vref(dv, ...)
end

local function vrefu(dv, ud, ...)
	dv.tag = C.FHKDV_REFU
	dv.ru_udata = ud.offset
	return vref(dv, ...)
end

ffi.metatype("fhkD_given", {
	__index = {
		set_vrefk = vrefk,
		set_vrefu = vrefu
	}
})

--------------------------------------------------------------------------------

return {
	compile_shapeinit = compile_shapeinit,
	gen               = drivergen,
	mcall_conv        = mcall_conv,
	mcall             = mcall,
	vrefk             = vrefk,
	vrefu             = vrefu
}
