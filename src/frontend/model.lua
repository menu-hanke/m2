local call = require "model.call"
local ffi = require "ffi"

return {
	lang = function(name)
		return require("model.model_" .. name)
	end,
	error = function()
		return ffi.string(ffi.C.model_error())
	end,
	parse_sig = call.parse_sig,
	prepare_call = call.prepare,
	call = call.call
}
