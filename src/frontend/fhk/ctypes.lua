local ffi = require "ffi"
local C = ffi.C
local bor, lshift = bit.bor, bit.lshift

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
	return bor(0x1000000000000ULL, bor(lshift(to, 16), from))
end

local function space(n)
	-- same as ss1(0, n)
	return bor(0x1000000000000ULL, lshift(n, 16))
end

return {
	ZERO_ARG = ZERO_ARG,
	ss1      = ss1,
	space    = space
}
