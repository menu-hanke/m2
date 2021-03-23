local modcall = require "fhk.modcall"
local compile = require "fhk.compile"

return {
	loader = function(...)
		local returns = {...}
		return {
			sigset = modcall.any_signature,
			compile = function(dispatch, signature)
				return compile.modcall_const(dispatch, signature, returns)
			end
		}
	end
}

