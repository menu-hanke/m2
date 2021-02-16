local def = require "control.def"
local emit = require "control.emit"
local export = require "control.export"
local simcontrol = require "control.simcontrol"

return {
	env           = def.env,
	read          = def.read,
	compile       = emit.compile,
	patch_exports = export.patch_exports,
	inject        = simcontrol.inject,

	-- this should go somewhere else
	exec          = function(insn, stack, idx, continue)
		return insn(stack or {}, idx or 0, continue or emit.exit_insn)
	end
}
