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

function data_mt.__index:fhk_map(name)
	local typ = self.type.vars[name]
	return typ and function(solver, mapper, var)
		return C.fhkM_pack_ptrV(
			mapper:infer_desc(var, typ),
			typing.memb_ptr(self.type.ctype, name, self.ptr)
		), true
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
