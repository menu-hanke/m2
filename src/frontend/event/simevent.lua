local plan = require "event.plan"

local function inject(env, def)
	local p = plan.create()

	env.m2.on("env:prepare", function()
		def:finalize()
		p:finalize(def, env.sim)
		p = nil
		def = nil
	end)

	env.m2.events = function()
		return p:set()
	end
end

return {
	inject = inject
}
