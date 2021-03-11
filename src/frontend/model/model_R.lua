local model = require "model"
local conv = require "model.conv"
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

return {
	def = function(fname, func)
		return {
			sigmask = conv.sigmask(C.mod_R_types()),
			create  = function(_, sig)
				local m = C.mod_R_create(fname, func, sig)
				if m == ffi.NULL then
					error(string.format("%s:%s failed to create R model: %s",
						fname, func, model.error()))
				end
				return m
			end
		}
	end
}
