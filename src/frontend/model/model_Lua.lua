local ffi = require "ffi"
local C = ffi.C

if not pcall(function() return C.mod_Lua_create end) then
	error("No Lua model support. You can enable it by setting MODEL_LANG in Makefile.")
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

	def_jit = function(module, func)
		return setmetatable({
			create = function(_, sig)
				return C.mod_LuaJIT_create(module, func, sig)
			end
		})
	end
}
