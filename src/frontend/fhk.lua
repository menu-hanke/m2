local ctypes = require "fhk.ctypes"
local simfhk = require "fhk.simfhk"
local def = require "fhk.def"

return {
	status_code = ctypes.status_code,
	status_arg  = ctypes.status_arg,
	status      = ctypes.status,
	ss1         = ctypes.ss1,
	space       = ctypes.space,
	ss_size     = ctypes.ss_size,
	ss_iter     = ctypes.ss_iter,
	ss_builder  = ctypes.ss_builder,
	subset      = ctypes.subset,
	fmt_error   = ctypes.fmt_error,

	def         = def.create,
	env         = def.env,
	read        = def.read,

	inject      = simfhk.inject
}
