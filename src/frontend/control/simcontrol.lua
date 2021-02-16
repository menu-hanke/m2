local cfg = require "control.cfg"
local emit = require "control.emit"
local export = require "control.export"
local misc = require "misc"

local function inject(env)
	env.m2.export = {}

	env.m2.control = {
		nothing        = cfg.nothing,
		exit           = cfg.exit,
		primitive      = cfg.primitive,
		all            = cfg.all,
		any            = cfg.any,
		optional       = cfg.optional,
		compile        = misc.delegate(env.sim, emit.compile),
		make_primitive = export.make_primitive
	}
end

return {
	inject = inject
}
