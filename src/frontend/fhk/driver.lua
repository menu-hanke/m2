local transform = require "fhk.transform"
local ctypes = require "fhk.ctypes"
local ffi = require "ffi"
local C = ffi.C

local umem_mt = { __index={} }

local function umem()
	return setmetatable({
		fields          = {},
		ctype_callbacks = {}
	}, umem_mt)
end

function umem_mt.__index:scalar(ctype, init)
	local name = string.format("_%d", #self.fields)
	table.insert(self.fields, {
		ctype = ctype,
		init  = init,
		name  = name
	})
	return name
end

function umem_mt.__index:on_ctype(f)
	table.insert(self.ctype_callbacks, f)
end

function umem_mt.__index:ctype()
	if self._ctype then
		return self._ctype
	end

	table.sort(self.fields, function(a, b)
		return ffi.sizeof(a.ctype) > ffi.sizeof(b.ctype)
	end)

	local ctypes, fields = {}, {}
	for _,f in ipairs(self.fields) do
		table.insert(ctypes, f.ctype)
		table.insert(fields, string.format("$ %s;", f.name))
	end

	self._ctype = ffi.typeof(
		string.format("struct { %s }", table.concat(fields, " ")),
		unpack(ctypes)
	)

	for _,f in ipairs(self.ctype_callbacks) do
		f(self._ctype)
	end

	return self._ctype
end

local function build(nodeset, alloc)
	-- put given variables first
	local vorder = {}
	for _,var in pairs(nodeset.vars) do
		table.insert(vorder, var)
	end
	table.sort(vorder, function(a, b) return a.create and not b.create end)

	local G, mapping = transform.build(nodeset, { vars=vorder }, alloc)

	local maxgiven = 0

	for i=0, G.nv-1 do
		if mapping.nodes[i].create then
			maxgiven = i
		end
	end

	local M = ffi.cast("fhkD_mapping *",
		alloc(ffi.sizeof("fhkD_mapping"), ffi.alignof("fhkD_mapping")))

	assert(ffi.alignof("fhkD_given") == ffi.alignof("fhkD_model"))
	local nodes = alloc(ffi.sizeof("fhkD_model")*G.nm + ffi.sizeof("fhkD_given")*(maxgiven+1),
		ffi.alignof("fhkD_given"))
	
	-- this also assigns M.vars, see driver.h
	M.models = ffi.cast("fhkD_model *", nodes) + G.nm
	M.maps = nil -- TODO

	local umem = umem()
	
	for i=0, maxgiven do
		if mapping.nodes[i].create then
			M.vars[i].trace = false
			mapping.nodes[i].create(M.vars+i, umem, nodeset)
		end
	end
	
	for i=-G.nm, -1 do
		M.models[i].trace = false
		mapping.nodes[i].create(M.models+i, umem, nodeset)
	end

	return G, mapping, M, umem
end

local function loop(sym, trace)
	local function continue(D)
		local status = C.fhkD_continue(D)

		if status == C.FHKD_OK then
			return
		elseif status == C.FHKDL_TRACE then
			trace(D, ctypes.status(D.tr_status))
		elseif status < 0 then
			return D.status:fmt_error(status, sym)
		else
			assert(false)
		end

		return continue(D)
	end

	return continue
end

------ models calls ----------------------------------------

local function conv(g_sig, m_sig, alloc)
	local convs = {}

	for i=0, g_sig.np-1 do
		if g_sig.typ[i] ~= m_sig.typ[i] then
			table.insert(convs, {ei=i, from=g_sig.typ[i], to=m_sig.typ[i]})
		end
	end

	local np = #convs

	for i=g_sig.np, g_sig.np+g_sig.nr-1 do
		if g_sig.typ[i] ~= m_sig.typ[i] then
			table.insert(convs, {ei=i, from=m_sig.typ[i], to=g_sig.typ[i]})
		end
	end

	local n = #convs
	local mconv = nil

	if n > 0 then
		mconv = ffi.cast("fhkD_conv *",
			alloc(n * ffi.sizeof("fhkD_conv"), ffi.alignof("fhkD_conv")))
		
		for i,c in ipairs(convs) do
			mconv[i-1].ei = c.ei
			mconv[i-1].from = c.from
			mconv[i-1].to = c.to
		end
	end

	return mconv, np, n
end

local function mcall(dm, fp, model, conv, np, n)
	dm.tag = C.FHKDM_MCALL
	dm.m_npconv = np or 0
	dm.m_nconv = n or 0
	dm.m_conv = conv or nil
	dm.m_fp = fp
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

local function vrefu(dv, offset, ...)
	dv.tag = C.FHKDV_REFU
	dv.ru_udata = offset
	return vref(dv, ...)
end

ffi.metatype("fhkD_given", {
	__index = {
		set_vrefk = vrefk,
		set_vrefu = vrefu
	}
})

------ status ----------------------------------------

ffi.metatype("fhkD_status", {
	__index = {
		fmt_error = function(self, ecode, sym)
			if ecode == C.FHKDE_CONV then return "type conversion error" end
			if ecode == C.FHKDE_MOD then
				return string.format("model call error: %s", require("model").error())
			end
			if ecode == C.FHKDE_FHK then
				local _, arg = ctypes.status(self.e_status)
				return string.format("fhk failed: %s", ctypes.errstr(arg.s_ei, sym))
			end

			assert(false)
		end
	}
})

--------------------------------------------------------------------------------

return {
	build = build,
	loop  = loop,
	conv  = conv,
	mcall = mcall,
	vrefk = vrefk,
	vrefu = vrefu
}
