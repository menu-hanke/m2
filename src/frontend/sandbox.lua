local misc = require "misc"

-- note: this is not a security sandbox, it's just to isolate simulator environments
-- from each other and the engine

local function capture(override)
	local pkg = misc.merge({
		path = package.path,
		cpath = package.cpath,
	}, override)

	pkg.loaded = pkg.loaded or {}

	-- this must never be re-required or luajit will break, so it's special-cased
	pkg.loaded.ffi = require("ffi")

	return pkg
end

local function _require(env, module)
	local package = env.package
	local err = {}

	for _,ld in ipairs(package.loaders) do
		local f = ld(module)
		if type(f) == "function" then
			-- don't break env for libraries
			-- TODO: remove this check and instead write a custom loader that checks for
			-- local files (like the package.path loader) and sets the env
			if getfenv(f) == _G and debug.getinfo(f).what ~= "C" then
				setfenv(f, env)
			end

			local m = f()
			if m == nil then
				m = true
			end

			package.loaded[module] = m
			return m
		elseif f then
			table.insert(err, f)
		end
	end

	error(string.format("Module '%s' not found: %s", module, table.concat(err, "\n")))
end

local function require(env, module)
	local mod = env.package.loaded[module]
	if mod then
		return mod
	end

	-- XXX: this is an awkward way to do it, hovewer the functions in package.loaders read
	-- the path/cpath from their (C) environment, so there is no good way to change it.
	-- ie. we _must_ change the actual package.path.
	-- ie. we must set it, then load, then restore it.
	-- Note: this doesn't prevent the script from modifying eg. package.loaders but it should
	-- cover most cases
	local path, cpath = package.path, package.cpath
	package.path = env.package.path
	package.cpath = env.package.cpath
	local ok, r = xpcall(_require, debug.traceback, env, module)
	package.path = path
	package.cpath = cpath

	if ok then
		return r
	end

	error(r, 2)
end

local function inject(env, pkg)
	env.package = misc.merge({}, package)
	env.package.path = pkg.path
	env.package.cpath = pkg.cpath
	env.package.loaded = misc.merge({}, pkg.loaded)
	env.require = misc.delegate(env, require)
end

return {
	capture = capture,
	inject  = inject
}
