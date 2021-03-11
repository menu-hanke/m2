local conv = require "model.conv"
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

return {
	def = function(module, func)
		return {
			sigmask = conv.sigmask(C.mod_Lua_types()),
			create  = function(_, sig)
				return C.mod_Lua_create(module, func, sig)
			end
		}
	end,

	def_jit = function(mf, name)
		if type(mf) == "function" then
			local info = debug.getinfo(mf)
			name = name or string.format("%s:%d", info.short_src, info.linedefined)
			if info.nups ~= 0 then
				error(string.format("%s: inline model function can't have upvalues", name))
			end

			return {
				sigmask = conv.sigmask(C.mod_Lua_types()),
				create  = function(_, sig)
					local bc = string.dump(mf)
					return C.mod_LuaBC_create(bc, #bc, name, sig)
				end
			}
		else
			return {
				sigmask = conv.sigmask(C.mod_Lua_types()),
				create  = function(_, sig)
					return C.mod_LuaJIT_create(mf, name, sig)
				end
			}
		end
	end
}
