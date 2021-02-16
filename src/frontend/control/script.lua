local function inject(env)
	env.m2.export = {}
end

return {
	inject = inject
}
