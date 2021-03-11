local ctypes = require "fhk.ctypes"
local simfhk = require "fhk.simfhk"
local fhkdbg = require "fhk.debugger"
local def = require "fhk.def"

return {
	errstr      = ctypes.errstr,
	status      = ctypes.status,
	ss1         = ctypes.ss1,
	space       = ctypes.space,
	subset      = ctypes.ssfromidx,
	subset_ffi  = ctypes.ssfromidx_ffi,

	env         = def.env,
	read        = def.read,

	def         = simfhk.def,
	inject      = simfhk.inject,

	cli         = fhkdbg.cli
}
