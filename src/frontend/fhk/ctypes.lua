local ffi = require "ffi"
local C = ffi.C
local bor, band, lshift, rshift = bit.bor, bit.band, bit.lshift, bit.rshift

-- this is only useful for debugging. calls to functions returning fhk_status aren't compiled.
ffi.metatype("fhk_status", {
	__index = {
		code   = function(self) return bit.band(self.r[0], 0xffff) end,
		A      = function(self) return bit.rshift(self.r[0], 48) end,
		B      = function(self) return bit.band(bit.rshift(self.r[0], 32), 0xffff) end,
		C      = function(self) return bit.band(bit.rshift(self.r[0], 16), 0xffff) end,
		ABC    = function(self) return bit.rshift(self.r[0], 16) end,
		X      = function(self) return self.r[1] end,
		Xudata = function(self) return ffi.new("fhk_arg", {u64=self.r[1]}) end
	}
})

local ZERO_ARG = ffi.new("fhk_arg", {u64=0})

ffi.metatype("fhk_def", {
	__index = {
		reset     = C.fhk_reset_def,
		destroy   = C.fhk_destroy_def,
		size      = C.fhk_graph_size,
		build     = function(self, p) return C.fhk_build_graph(self, p) end,
		add_model = function(self, group, k, c, udata)
			return C.fhk_def_add_model(self, group, k, c, udata or ZERO_ARG)
		end,
		add_var   = function(self, group, size, udata)
			return C.fhk_def_add_var(self, group, size, udata or ZERO_ARG)
		end,
		add_param = function(self, model, var, map, arg)
			C.fhk_def_add_param(self, model, var, map, arg or ZERO_ARG)
		end,
		add_return = function(self, model, var, map, arg)
			C.fhk_def_add_return(self, model, var, map, arg or ZERO_ARG)
		end,
		add_check  = function(self, model, var, map, arg, op, oparg, penalty)
			C.fhk_def_add_check(self, model, var, map, arg or ZERO_ARG, op, oparg or ZERO_ARG, penalty)
		end
	}
})

ffi.metatype("fhk_graph", {
	__index = {
		set_dsym = C.fhk_set_dsym,
		reduce = function(self, arena, flags)
			local fxi = ffi.new("uint16_t[1]")
			local S = C.fhk_reduce(self, arena, flags, fxi)
			if S ~= ffi.NULL then
				return S
			else
				return nil, fxi[0]
			end
		end
	}
})

local function idxorskip(idx)
	return idx ~= C.FHK_SKIP and idx or nil
end

ffi.metatype("struct fhk_subgraph", {
	__index = {
		var   = function(self, idx) return idxorskip(self.r_vars[idx]) end,
		model = function(self, idx) return idxorskip(self.r_models[idx]) end,
		umap  = function(self, idx) return idxorskip(self.r_umaps[idx]) end,
		group = function(self, idx) return idxorskip(self.r_groups[idx]) end
	}
})

local function ss1(from, to)
	return bor(lshift(to, 16), from)
end

local function space(n)
	-- same as ss1(0, n)
	return lshift(n, 16)
end

-- pure lua versions of RANGE_LEN and ss_size_nonempty/ss_complex_size
local function range_len(range)
	return band(rshift(range, 16), 0xffff) - band(range, 0xffff)
end

-- this doesn't handle fast singletons (which is an fhk internal detail), ie. all ranges
-- must have a valid end
local function ss_size(ss)
	local n = tonumber(rshift(ss, 49))
	if n == 0 then
		return range_len(ss)
	end

	-- n may be 0 and that's ok,
	-- then the loop will not do any iterations

	local l = 0
	local p = ffi.cast("uint32_t *", band(ss, 0xffffffffffffULL))
	for i=0, n do
		l = l + range_len(p[i])
	end

	return l
end

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

local function fmt_error(code, flags, ei, syms)
	local info = {}

	if bit.band(flags, C.FHKEI_G) ~= 0 then
		table.insert(info, string.format("group: %d", ei.g))
	end

	if bit.band(flags, C.FHKEI_V) ~= 0 then
		table.insert(info, string.format("var: %s", (syms and syms.vars and syms.vars[ei.v]) or ei.v))
	end

	if bit.band(flags, C.FHKEI_M) ~= 0 then
		table.insert(info, string.format("model: %s", (syms and syms.models and syms.models[ei.m]) or ei.m))
	end

	if bit.band(flags, C.FHKEI_I) ~= 0 then
		table.insert(info, string.format("instance: %d", ei.i))
	end

	info = #info > 0 and string.format(" [%s]", table.concat(info, ", ")) or ""
	return string.format("%s%s", ffi.string(ei.desc), info)
end

return {
	ZERO_ARG   = ZERO_ARG,
	ss1        = ss1,
	space      = space,
	ss_size    = ss_size,
	ss_builder = ss_builder,
	subset     = subset,
	fmt_error  = fmt_error
}
