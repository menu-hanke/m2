local def = require "control.def"
local run = require "control.run"
local emit = require "control.emit"
local export = require "control.export"
local simcontrol = require "control.simcontrol"

return {
	env           = def.env,
	read          = def.read,
	compile       = emit.compile,
	patch_exports = export.patch_exports,
	inject        = simcontrol.inject,
	copystack     = run.copystack,
	exec          = run.exec
}
