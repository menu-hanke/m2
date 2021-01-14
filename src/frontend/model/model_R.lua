local model = require "model"
local ffi = require "ffi"
local C = ffi.C

if not pcall(function() return C.mod_R_create end) then
	return {}
end

ffi.metatype("mod_R", {
	__index = {
		call    = C.mod_R_call,
		destroy = C.mod_R_destroy
	}
})

local def_mt = { __index={} }

function def_mt.__index:param_types()
	return C.mod_R_types()
end

function def_mt.__index:return_types()
	return C.mod_R_types()
end

return {
	def = function(fname, func)
		return setmetatable({
			create = function(_, sig)
				local m = C.mod_R_create(fname, func, sig)
				if m == ffi.NULL then
					error(string.format("%s:%s failed to create R model: %s",
						fname, func, model.error()))
				end
				return m
			end
		}, def_mt)
	end
}
