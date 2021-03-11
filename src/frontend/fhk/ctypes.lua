local ffi = require "ffi"
local C = ffi.C
local bor, band, lshift, rshift = bit.bor, bit.band, bit.lshift, bit.rshift

---- error handling ----------------------------------------

local errmsg = {
	[C.FHKE_NYI]       = "not yet implemented",
	[C.FHKE_INVAL]     = "invalid value",
	[C.FHKE_OVERWRITE] = "illegal overwrite",
	[C.FHKE_DEPTH]     = "work stack limit exceeded",
	[C.FHKE_NVALUE]    = "missing value",
	[C.FHKE_MEM]       = "failed to allocate memory",
	[C.FHKE_CHAIN]     = "no chain with finite cost"
}

local errtag = {
	[C.FHKEI_I]        = "index",
	[C.FHKEI_J]        = "instance",
	[C.FHKEI_G]        = "group",
	[C.FHKEI_P]        = "usermap"
}

local function einfo(ei)
	local ecode = band(ei, 0xff)
	local tag1 = band(rshift(ei, 8), 0xf)
	local tag2 = band(rshift(ei, 12), 0xf)
	return tonumber(ecode),
		(tag1 ~= 0 and tonumber(tag1)),
		(tag1 ~= 0 and tonumber(ffi.cast("int16_t", band(rshift(ei, 16), 0xffff)))),
		(tag2 ~= 0 and tonumber(tag2)), 
		(tag2 ~= 0 and tonumber(ffi.cast("int16_t", band(rshift(ei, 32), 0xffff))))
end

local function tagstr(tag, val, sym)
	if tag == C.FHKEI_I and sym and sym[val] then
		return "index: " .. sym[val]
	end
	return string.format("%s: %d", errtag[tag], val)
end

local function errstr(ei, sym)
	if ei == 0 then
		return "ok"
	end

	local ecode, tag1, v1, tag2, v2 = einfo(ei)
	local mes = { errmsg[ecode] }
	if tag1 then table.insert(mes, tagstr(tag1, v1, sym)) end
	if tag2 then table.insert(mes, tagstr(tag2, v2, sym)) end
	return table.concat(mes, " ")
end

local function check(ei)
	if ei ~= 0 and ei < 0xffffffffffffull then
		error(errstr(ei))
	end
	return ei
end

---- solver status ----------------------------------------

local function status_code(status)
	return tonumber(band(status, 0xffff))
end

local function status_arg(status)
	return ffi.new("fhk_sarg", {u64=rshift(status, 16)})
end

local function status(s)
	return status_code(s), status_arg(s)
end

---- ffi metatypes ----------------------------------------

ffi.metatype("fhk_def", {
	__index = {
		destroy    = C.fhk_destroy_def,
		size       = C.fhk_graph_size,
		idx        = C.fhk_graph_idx,
		build      = function(self, p)
			local g = C.fhk_build_graph(self, p)
			if g == ffi.NULL then
				error("failed to allocate memory")
			end
			return g
		end,
		add_model  = function(self, group, k, c, cmin)
			return check(C.fhk_def_add_model(self, group, k, c, cmin or k))
		end,
		add_var    = function(self, group, size, cdiff)
			return check(C.fhk_def_add_var(self, group, size, cdiff or 0))
		end,
		add_shadow = function(self, var, guard, arg)
			return check(C.fhk_def_add_shadow(self, var, guard, arg))
		end,
		add_param  = function(self, model, var, map)
			check(C.fhk_def_add_param(self, model, var, map))
		end,
		add_return = function(self, model, var, map)
			check(C.fhk_def_add_return(self, model, var, map))
		end,
		add_check  = function(self, model, shadow, map, penalty)
			check(C.fhk_def_add_check(self, model, shadow, map, penalty))
		end
	}
})

ffi.metatype("fhk_solver", {
	__index = {
		continue    = C.fhk_continue,
		shape       = C.fhkS_shape,
		shape_table = C.fhkS_shape_table,
		give        = C.fhkS_give,
		give_all    = C.fhkS_give_all
	}
})

local inspect = {
	cost  = C.fhkI_cost,
	G     = C.fhkI_G,
	shape = function(...)
		local shape = C.fhkI_shape(...)
		return shape ~= C.FHK_NINST and shape or nil
	end,
	chain = function(...)
		local chain = C.fhkI_chain(...)
		if chain.idx ~= C.FHK_NIDX then
			return chain.idx, chain.inst
		end
	end,
	value = function(...)
		local p = C.fhkI_value(...)
		if p ~= ffi.NULL then
			return p
		end
	end
}

ffi.metatype("fhk_prune", {
	__index = {
		flags  = C.fhk_prune_flags,
		bounds = C.fhk_prune_bounds,
		prune  = C.fhk_prune_run -- unchecked, you must check the result yourself
	},
	__call = function(self)
		check(C.fhk_prune_run(self))
	end
})

---- subsets ----------------------------------------
-- see fhk/fhk.h and fhk/solve.c for description of the subset representation.
-- these functions are lua translations of the macros in fhk/solve.c
-- note: all intervals are inclusive

local function pkrangens(from, nsize1)
	return bor(lshift(nsize1, 16), from)
end

local function pkrange(from, to)
	return pkrangens(from, from-to)
end

local function ss1ns(from, nsize1)
	return bor(bor(lshift(ffi.cast("int64_t", nsize1), 32), lshift(from, 16)), 0xffff000000000000ull)
end

local function ss1(from, to)
	return ss1ns(from, from-to)
end

local function space(n)
	if n > 0 then
		return ss1ns(0, 1-n)
	else
		return 0
	end
end

local function complex(ip, n)
	return bor(lshift(ip, 16), n)
end

local function ssfromidx_complex(idx, i, start, pos, allocu32)
	local intervals = { pkrange(start, pos) }
	start = idx[i]
	pos = start
	i = i+1

	while i <= #idx do
		local p = idx[i]
		if p == pos+1 then
			pos = p
		else
			intervals[#intervals+1] = pkrange(start, pos)
			start, pos = p, p
		end
		i = i+1
	end

	intervals[#intervals+1] = pkrange(start, pos)

	local ip = allocu32(#intervals)

	for i=1, #intervals do
		ip[i-1] = intervals[i]
	end

	return complex(ffi.cast("uintptr_t", ip), #intervals-1), ip
end

local function ssfromidx(idx, allocu32)
	if #idx == 0 then
		return 0
	end

	table.sort(idx)

	local start = idx[1]
	local pos = start
	local i = 2
	while i <= #idx do
		local p = idx[i]
		if p == pos+1 then
			pos = p
		else
			return ssfromidx_complex(idx, i, start, pos, allocu32)
		end
		i = i+1
	end

	return ss1(start, pos)
end

local function ffi_allocu32(n)
	return ffi.new("uint32_t[?]", n)
end

local function ssfromidx_ffi(idx)
	return ssfromidx(idx, ffi_allocu32)
end

local function ss_numi(ss)
	return tonumber(band(ss, 0xffff))
end

local function ss_cptr(ss)
	return ffi.cast("int32_t *", rshift(ss, 16))
end

local function ss_size(ss)
	local n = ss_numi(ss)
	if n == 0 then
		return 1 + band(-rshift(ss, 32), 0xffff)
	else
		local pp = ss_cptr(ss)
		local size = n+1
		while n >= 0 do
			size = size - rshift(pp[0], 16)
			pp = pp+1
			n = n-1
		end
		return size
	end
end

--------------------------------------------------------------------------------

return {
	errstr        = errstr,
	status        = status,
	inspect       = inspect,
	ss1           = ss1,
	space         = space,
	complex       = complex,
	ssfromidx     = ssfromidx,
	ssfromidx_ffi = ssfromidx_ffi,
	ss_size       = ss_size,
	shvalue       = ffi.typeof "fhk_shvalue"
}
