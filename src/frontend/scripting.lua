local sandbox = require "sandbox"

local default_sandbox

local function init_sandbox(box)
	default_sandbox = box
end

local function inject_libraries(env)
	env.m2.libraries = {}
	env.m2.library = function(lib)
		table.insert(env.m2.libraries, lib)
	end
end

local function create_env(sim)
	local env = setmetatable({ m2 = { sim=sim } }, {__index=_G})
	sandbox.inject(env, default_sandbox)
	env.package.loaded.m2 = env.m2
	inject_libraries(env)
	return env
end

local function hook(env, name, ...)
	for _,lib in ipairs(env.m2.libraries) do
		if lib[name] then
			lib[name](...)
		end
	end
end

return {
	init_sandbox = init_sandbox,
	env          = create_env,
	hook         = hook
}
