local transform = require "fhk.transform"
local ctypes = require "fhk.ctypes"
local ffi = require "ffi"

local function dispatch_ok() end

local function dispatch_err(disp, syms)
	return function()
		error(ctypes.errstr(disp.arg.s_ei, syms))
	end
end

local function givnum(mapping)
	-- XXX: this assumes given variables are first (currently true),
	-- and that the graph builder will not reorder variables (currently true).
	-- make sure to keep this in sync with build.c
	local num = 0
	while mapping.nodes[num] and mapping.nodes[num].create do
		num = num+1
	end
	return num
end

local function unum(mapping)
	local inum, knum = -1, 0
	while mapping.umaps[inum] do inum = inum - 1 end
	while mapping.umaps[knum] do knum = knum + 1 end
	return -(inum+1), knum
end

local function build(nodeset, alloc)
	-- put given variables first
	local vorder = {}
	for _,var in pairs(nodeset.vars) do
		table.insert(vorder, var)
	end
	table.sort(vorder, function(a, b) return a.create and not b.create end)

	local G, mapping = transform.build(nodeset, { vars=vorder }, alloc)
	local syms = transform.symbols(mapping)
	local givnum = givnum(mapping)
	local inum, knum = unum(mapping)

	local dispatch = ffi.cast("fhkD_dispatch *",
		alloc(ffi.sizeof("fhkD_dispatch"), ffi.alignof("fhkD_dispatch")))

	local u16 = 2 -- ffi.sizeof/ffi.alignof("uint16_t")
	dispatch.vref     = alloc(givnum*u16, u16)
	dispatch.mapcall  = inum + ffi.cast("uint16_t *", alloc((inum+knum)*u16, u16))
	dispatch.modcall  = G.nm + ffi.cast("uint16_t *", alloc(G.nm*u16, u16))

	local jumptable = { [0]=dispatch_ok, [1]=dispatch_err(dispatch, syms) }
	local dispinfo = { dispatch = dispatch, jumptable = jumptable }

	for i=0, givnum-1 do
		table.insert(jumptable, mapping.nodes[i].create(dispinfo, i, nodeset))
		dispatch.vref[i] = #jumptable
	end

	for i=-G.nm, -1 do
		table.insert(jumptable, mapping.nodes[i].create(dispinfo, i, nodeset))
		dispatch.modcall[i] = #jumptable
	end

	for i=-inum, knum-1 do
		table.insert(jumptable, mapping.umaps[i].create(dispinfo, i, nodeset))
		dispatch.mapcall[i] = #jumptable
	end

	return { G=G, mapping=mapping, syms=syms }, dispinfo
end

return {
	build = build
}
