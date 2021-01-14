local ffi = require "ffi"
local C = ffi.C

if not pcall(function() return C.mod_Lua_create end) then
	return {}
end

ffi.metatype("mod_Lua", {
	__index = {
		call    = C.mod_Lua_call,
		destroy = C.mod_Lua_destroy
	}
})

local def_mt = { __index={} }

function def_mt.__index:param_types()
	return C.mod_Lua_types()
end

function def_mt.__index:return_types()
	return C.mod_Lua_types()
end

-- TODO: co
return {
	def = function(module, func)
		return setmetatable({
			create = function(_, sig)
				return C.mod_Lua_create(module, func, sig)
			end
		}, def_mt)
	end,

	def_jit = function(mf, name)
		if type(mf) == "function" then
			local info = debug.getinfo(mf)
			name = name or string.format("%s:%d", info.short_src, info.linedefined)
			if info.nups ~= 0 then
				error(string.format("%s: inline model function can't have upvalues", name))
			end
			return setmetatable({
				create = function(_, sig)
					local bc = string.dump(mf)
					return C.mod_LuaBC_create(bc, #bc, name, sig)
				end
			}, def_mt)
		else
			return setmetatable({
				create = function(_, sig)
					return C.mod_LuaJIT_create(mf, name, sig)
				end
			}, def_mt)
		end
	end
}
