local conv = require "model.conv"
local ffi = require "ffi"
local C = ffi.C

-- lua -> model calls are slow and mostly for testing, or if you REALLY need to call models
-- manually in non-perf sensitive pers (eg. during initialization).
-- don't use the functions below in perf sensitive code (call them via fhk instead).
--
-- TODO: a better way to do this is to precompute a table with the ctypes and use that

local function parse_sig(s)
	local npnr = ffi.new("uint8_t[2]")
	if C.mt_sig_info(s, npnr+0, npnr+1) ~= 0 then
		error(string.format("invalid signature: %s", s))
	end

	local mts_p = C.malloc(ffi.sizeof("struct mt_sig") + (npnr[0] + npnr[1]) * ffi.sizeof("mt_type"))
	local mts = ffi.gc(ffi.cast("struct mt_sig *", mts_p), C.free)
	mts.np = npnr[0]
	mts.nr = npnr[1]
	C.mt_sig_parse(s, mts.typ)
	return mts
end

local function prepare(arena, sig, e)
	local mcs = ffi.cast("mcall_s *", arena:malloc(ffi.sizeof("mcall_s")
		+ (sig.np+sig.nr)*(ffi.sizeof("void *") + ffi.sizeof("size_t"))))

	mcs.np = sig.np
	mcs.nr = sig.nr

	for i=0, sig.np-1 do
		local isset = conv.isset(sig.typ[i])
		mcs.edges[i].n = isset and #e[i+1] or 1
		local ct = conv.ctypeof(sig.typ[i])
		local p = arena:new(ct, mcs.edges[i].n)
		mcs.edges[i].p = p
		if isset then
			for j, x in ipairs(e[i+1]) do
				p[j-1] = x
			end
		else
			p[0] = e[i+1]
		end
	end

	for i=sig.np, sig.np+sig.nr-1 do
		mcs.edges[i].n = e[i+1] or 1
		mcs.edges[i].p = arena:malloc(mcs.edges[i].n * conv.sizeof(sig.typ[i]))
	end

	return mcs
end

local function call(mp, mcs, sig)
	local res = mp:call(mcs)

	local rv = {}

	for i=sig.np, sig.np+sig.nr-1 do
		local p = ffi.cast(ffi.typeof("$ *", conv.ctypeof(sig.typ[i])), mcs.edges[i].p)
		if conv.isset(sig.typ[i]) then
			local t = {}
			for j=0, tonumber(mcs.edges[i].n)-1 do
				t[j+1] = p[j]
			end
			table.insert(rv, t)
		else
			table.insert(rv, p[0])
		end
	end

	return res, rv
end

return {
	parse_sig = parse_sig,
	prepare   = prepare,
	call      = call
}
