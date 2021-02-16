local misc = require "misc"
local cfg = require "control.cfg"
local export = require "control.export"

local function idef_env()
	local env = setmetatable({
		nothing   = cfg.nothing,
		exit      = cfg.exit,
		primitive = cfg.primitive,
		all       = cfg.all,
		any       = cfg.any,
		optional  = cfg.optional,
		sim       = export.exports()
	}, { __index=_G })

	env.read = function(fname) return misc.dofile_env(env, fname) end
	return env
end

local function read(fname)
	return idef_env().read(fname)
end

return {
	env  = idef_env,
	read = read,
}
