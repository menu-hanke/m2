local simevent = require "event.simevent"
local def = require "event.def"

return {
	def    = def.create,
	env    = def.env,
	read   = def.read,
	inject = simevent.inject
}
