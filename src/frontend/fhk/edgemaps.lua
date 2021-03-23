local compile = require "fhk.compile"
local graph = require "fhk.graph"

local function ufunc(func, flags)
	flags = flags or "i"
	local compiler = graph.isconst(flags) and compile.mapcall_k or compile.mapcall_i
	return graph.ufunc(function(dispatch, idx) return compiler(dispatch, idx, func) end, flags)
end

return {
	ufunc = ufunc,
	umap  = graph.umap
}
