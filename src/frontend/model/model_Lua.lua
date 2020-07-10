local ffi = require "ffi"
local C = ffi.C

if not pcall(function() return C.mod_Lua_create end) then
	error("No Lua model support. You can enable it by setting MODEL_LANG in Makefile.")
end

ffi.metatype("mod_Lua", {
	__index = {
		call = C.mod_Lua_call
	},
	__gc = C.mod_Lua_destroy
})

local def_mt = { __index={} }

function def_mt.__index:param_types()
	return C.mod_Lua_types()
end

function def_mt.__index:return_types()
	return C.mod_Lua_types()
end

function def_mt.__index:create(sig)
	-- TODO co
	return C.mod_Lua_create(self.module, self.func, sig, 0)
end

return {
	def = function(module, func)
		return setmetatable({
			module = module,
			func   = func,
		}, def_mt)
	end
}
