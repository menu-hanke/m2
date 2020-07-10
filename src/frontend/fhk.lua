local simfhk = require "fhk.simfhk"
local def = require "fhk.def"

return {
	def    = def.create,
	env    = def.env,
	read   = def.read,
	inject = simfhk.inject
}
