local function signature()
	return {
		params  = {},
		returns = {}
	}
end

local function loader(lang, ...)
	return require("fhk.modcall." .. lang).loader(...)
end

return {
	signature     = signature,
	any_signature = signature(),
	loader        = loader
}
