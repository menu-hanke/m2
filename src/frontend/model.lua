local call = require "model.call"

return {
	lang = function(name)
		return require("model.model_" .. name)
	end,
	parse_sig = call.parse_sig,
	prepare_call = call.prepare,
	call = call.call
}
