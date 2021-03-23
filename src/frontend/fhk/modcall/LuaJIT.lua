local modcall = require "fhk.modcall"
local compile = require "fhk.compile"

return {
	loader = function(module, name)
		return {
			sigset = modcall.any_signature,
			compile = function(dispatch, signature)
				return compile.modcall_lua_ffi(dispatch, signature,
					require(module)[name]
					or error(string.format("module '%s' doesn't export funcion '%s'", module, name)),
					name
				)
			end
		}
	end
}
