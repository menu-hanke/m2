local ffi = require "ffi"
local C = ffi.C
local bor, band, lshift, rshift = bit.bor, bit.band, bit.lshift, bit.rshift

---- ffi metatypes ----------------------------------------

local deferror = {
	[C.FHKDE_MEM]   = "failed to allocate memory",
	[C.FHKDE_INVAL] = "invalid value",
	[C.FHKDE_IDX]   = "index out of bounds"
}

local function defcheck(e)
	if e ~= 0 then
		error(deferror[e] or string.format("def error: %d", e))
	end
end

local _idx_arg = ffi.new("fhk_idx[1]")

ffi.metatype("fhk_def", {
	__index = {
		reset      = C.fhk_reset_def,
		destroy    = C.fhk_destroy_def,
		size       = C.fhk_graph_size,
		build      = function(self, p) return C.fhk_build_graph(self, p) end,
		add_model  = function(self, group, k, c)
			defcheck(C.fhk_def_add_model(self, _idx_arg, group, k, c))
			return _idx_arg[0]
		end,
		add_var    = function(self, group, size)
			defcheck(C.fhk_def_add_var(self, _idx_arg, group, size))
			return _idx_arg[0]
		end,
		add_param  = function(self, model, var, map)
			defcheck(C.fhk_def_add_param(self, model, var, map))
		end,
		add_return = function(self, model, var, map)
			defcheck(C.fhk_def_add_return(self, model, var, map))
		end,
		add_check  = function(self, model, var, map, cst)
			defcheck(C.fhk_def_add_check(self, model, var, map, cst))
		end
	}
})

ffi.metatype("fhk_graph", {
	__index = {
		set_dsym = C.fhk_set_dsym,
		reduce = function(self, arena, flags)
			local S = C.fhk_reduce(self, arena, flags, _idx_arg)
			if S ~= ffi.NULL then
				return S
			else
				return nil, _idx_arg[0]
			end
		end
	}
})

ffi.metatype("fhk_solver", {
	__index = {
		continue    = C.fhk_continue,
		shape       = C.fhkS_shape,
		shape_table = C.fhkS_shape_table,
		give        = C.fhkS_give,
		give_all    = C.fhkS_give_all,
		use_mem     = C.fhkS_use_mem
	}
})

local fpop = {
	[">="] = C.FHKC_GEF64,
	["<="] = C.FHKC_LEF64
}

assert(C.FHKC_GEF32 == C.FHKC_GEF64 + C.FHKC__NUM_FP)
assert(C.FHKC_LEF32 == C.FHKC_LEF64 + C.FHKC__NUM_FP)

ffi.metatype("fhk_cst", {
	__index = {
		set_u8_mask64 = function(self, mask)
			self.op = C.FHKC_U8_MASK64
			self.arg.u64 = mask
		end,

		-- op: "<=", ">=", "<", ">"
		-- TODO: nextafter w/ strict comparisons
		set_cmp_fp32  = function(self, op, f32)
			self.op = fpop[op] + C.FHKC__NUM_FP
			self.arg.f32 = f32
		end,

		set_cmp_fp64  = function(self, op, f64)
			self.op = fpop[op]
			self.arg.f64 = f64
		end
	}
})

local function idxorskip(idx)
	return idx ~= C.FHKR_SKIP and idx or nil
end

ffi.metatype("struct fhk_subgraph", {
	__index = {
		var   = function(self, idx) return idxorskip(self.r_vars[idx]) end,
		model = function(self, idx) return idxorskip(self.r_models[idx]) end
	}
})

---- Subsets ----------------------------------------
-- Pure Lua versions of subset functions in fhk/solve.c
-- the subset format is documented in fhk/solve.c

-- ss1 subsets (subsets that contain exactly one range)

local function ss1(from, to)
	return bor(lshift(to, 16), from)
end

local function unss1(ss)
	return band(ss, 0xffff), band(rshift(ss, 16), 0xffff)
end

local function ss1_len(range)
	local from, to = unss1(range)
	return to - from
end

local function space(n)
	-- same as ss1(0, n)
	return lshift(n, 16)
end

-- complex subsets (collections of multiple ranges)

local complex_bit = 2^48

local function ss_is1(ss)
	return ss < complex_bit
end

-- this doesn't handle fast singletons (which is an fhk internal detail), ie. all ranges
-- must have a valid end
local function ss_size(ss)

	-- Note: you can't check (ss>>49) here because if ss is a lua number, then luajit
	-- will perform the bit op as 32 bit (ie. it will end up doing ((uint32_t)ss) >> 17)
	if ss_is1(ss) then
		return ss1_len(ss)
	end

	local n = tonumber(rshift(ss, 49))
	assert(n > 0)

	local l = 0
	local p = ffi.cast("uint32_t *", band(ss, 0xffffffffffffULL))
	for i=0, n-1 do
		l = l + ss1_len(p[i])
	end

	return l
end

local function _yield_ss1(ss)
	local from, to = unss1(ss)
	for i=tonumber(from), tonumber(to)-1 do
		coroutine.yield(i)
	end
end

-- this will not be compiled, only use it for testing/setup code
local function ss_iter(ss)
	return coroutine.wrap(function()
		if ss_is1(ss) then
			_yield_ss1(ss)
			return
		end

		local n = tonumber(rshift(ss, 49))
		assert(n > 0)

		local p = ffi.cast("uint32_t *", band(ss, 0xffffffffffffULL))
		for i=0, n-1 do
			_yield_ss1(p[i])
		end
	end)
end

-- utility to build sets from Lua numbers.
-- This is slow and causes allocations, do not use in perf sensitive code.

local setbuilder_mt = { __index = {} }

-- from: self[-1], self[-2], ...
-- to:   self[1], self[2], ...
local function ss_builder()
	return setmetatable({}, setbuilder_mt)
end

local function subset(ind, arena)
	local builder = ss_builder()
	for _,i in ipairs(ind) do
		builder:add(i)
	end
	return builder:to_subset(arena)
end

function setbuilder_mt.__index:add(from, to)
	to = to or (from + 1)

	-- this is never true when the set builder is empty - self[0] = nil
	if from == self[#self] then
		self[#self] = to
		return self
	end

	self[-(#self+1)] = from
	self[#self+1] = to
	return self
end

-- if you don't pass arena, then make sure to keep the second return value alive until you're
-- done using the subset, or luajit will gc it
function setbuilder_mt.__index:to_subset(arena)
	if #self == 1 then return ss1(self[-1], self[1]) end
	if #self == 0 then return 0ULL end

	local p = arena and arena:new("uint32_t", #self) or ffi.new("uint32_t[?]", #self)

	for i=1, #self do
		p[i-1] = bor(lshift(self[i], 16), self[-i])
	end

	return bor(lshift(ffi.cast("uint64_t", #self-1), 49) + lshift(1ULL, 48), ffi.cast("uintptr_t", p)), p
end

---- Statuses ----------------------------------------

local function status_code(status)
	return tonumber(band(status, 0xffff))
end

local function status_arg(status)
	return ffi.new("fhk_sarg", {u64=rshift(status, 16)})
end

local function status(s)
	return status_code(s), status_arg(s)
end

local ecode = {
	[C.FHKE_NYI]     = "NYI",
	[C.FHKE_INVAL]   = "invalid value",
	[C.FHKE_REWRITE] = "invalid overwrite",
	[C.FHKE_DEPTH]   = "max recursion depth",
	[C.FHKE_VALUE]   = "missing value",
	[C.FHKE_MEM]     = "failed to allocate memory",
	[C.FHKE_CHAIN]   = "no chain with finite cost"
}

local ewhere = {
	[C.FHKF_SOLVER]  = "solver",
	[C.FHKF_CYCLE]   = "cycle solver",
	[C.FHKF_SHAPE]   = "shape table",
	[C.FHKF_GIVE]    = "given variable",
	[C.FHKF_MEM]     = "external memory",
	[C.FHKF_MAP]     = "user mapping",
	[C.FHKF_SCRATCH] = "scratch buffer"
}

local etag = {
	[C.FHKEI_G]      = "group",
	[C.FHKEI_V]      = "variable",
	[C.FHKEI_M]      = "model",
	[C.FHKEI_P]      = "map",
	[C.FHKEI_I]      = "instance"
}

local function fmt_error(ei, syms)
	local info = {}

	if ei.ecode > 0 then
		table.insert(info, ecode[ei.ecode])
	end

	if ei.where > 0 then
		table.insert(info, string.format("(%s)", ewhere[ei.where]))
	end

	for _,tv in ipairs({{ei.tag1, ei.v1}, {ei.tag2, ei.v2}}) do
		local t, v = tv[1], tv[2]
		if t > 0 then
			if t == C.FHKEI_V and syms and syms.vars and syms.vars[v] then
				v = syms.vars[v]
			elseif t == C.FHKEI_M and syms and syms.models and syms.models[m] then
				v = syms.models[v]
			end

			table.insert(info, string.format("%s: %s", etag[t], v))
		end
	end

	return table.concat(info, " ")
end

return {
	status_code = status_code,
	status_arg  = status_arg,
	status      = status,
	ss1         = ss1,
	space       = space,
	ss_size     = ss_size,
	ss_iter     = ss_iter,
	ss_builder  = ss_builder,
	subset      = subset,
	fmt_error   = fmt_error
}
