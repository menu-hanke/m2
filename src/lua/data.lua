local typing = require "typing"
local ffi = require "ffi"
local C = ffi.C

local data_mt = { __index={}  }

local function new(sim, typ, func, life)
	life = life or C.SIM_VSTACK
	if func then ffi.metatype(typ.ctype, {__index=func}) end
	local p = C.sim_alloc(sim, ffi.sizeof(typ.ctype), ffi.alignof(typ.ctype), life)
	return setmetatable({ type = typ, ptr = p }, data_mt), ffi.cast(ffi.typeof("$ *", typ.ctype), p)
end

function data_mt.__index:define_mappings(def, map)
	local base = ffi.cast("char *", self.ptr)
	for name, offset, size in typing.offsets(self.type) do
		map(name, function(desc)
			local mapping = def.arena:new("struct fhkM_dataV")
			mapping.flags.resolve = C.FHKM_MAP_DATA
			mapping.flags.type = typing.demote(desc, size)
			mapping.ref = base + offset
			return mapping, true
		end)
	end
end

local function inject(env)
	env.m2.data = {
		static = function(typ, func)
			return new(env.sim._sim, typing.totype(typ), func, C.SIM_STATIC)
		end,

		dynamic = function(typ, func)
			return new(env.sim._sim, typing.totype(typ), func, C.SIM_VSTACK)
		end
	}
end

return {
	inject = inject
}
