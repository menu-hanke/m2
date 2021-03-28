local compile = require "fhk.compile"

local function signature(params, returns)
	return {
		params  = params or {},
		returns = returns or params or {}
	}
end

local function fff_compiler(lang, create)
	return function(dispatch, signature, udata)
		if not udata.fff_state then
			udata.fff_state = require("fff").state()
		end
		local handle, name = create(udata.fff_state, signature, udata)
		udata.fff_state:checkerr(true)
		return compile.modcall_fff(dispatch, udata.fff_state, lang, handle, name)
	end
end

local function loader(lang, ...)
	return require("fhk.modcall." .. lang).loader(...)
end

return {
	signature     = signature,
	any_signature = signature(),
	fff_compiler  = fff_compiler,
	loader        = loader
}
