local typing = require "typing"

local uniqname = (function()
	local _u = 0
	return function()
		_u = _u + 1
		return string.format("__test_type_%d", _u)
	end
end)()

local function builtins(vs, name)
	local t = typing.newtype(name or uniqname())
	for f,v in pairs(vs) do
		t.vars[f] = typing.builtin_types[v]
	end
	return t
end

local function reals(...)
	local t = typing.newtype(uniqname())
	for _,name in ipairs({...}) do
		t.vars[name] = typing.builtin_types.real
	end
	return t
end

return {
	builtins = builtins,
	reals    = reals
}
