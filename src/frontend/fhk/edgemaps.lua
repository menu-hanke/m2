local compile = require "fhk.compile"
local graph = require "fhk.graph"

local function ufuncname(func)
	local info = debug.getinfo(func)
	return string.format("%s:%d", info.short_src, info.linedefined)
end

local function ufunc(func, flags)
	flags = flags or "i"
	local compiler = graph.isconst(flags) and compile.mapcall_k or compile.mapcall_i
	return graph.ufunc(
		function(dispatch, idx) return compiler(dispatch, idx, func) end,
		flags,
		ufuncname(func)
	)
end

return {
	ufunc = ufunc,
	umap  = graph.umap
}
