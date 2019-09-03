local ffi = require "ffi"

ffi.metatype("ex_func", {
	__call = ffi.C.ex_exec,
	__gc = ffi.C.ex_destroy
})

local create_ex = {
	R     = ffi.C.ex_R_create,
	simoC = ffi.C.ex_simoC_create
}

local function create(impl, narg, argt, nret, rett)
	local cr = create_ex[impl.lang]

	if not cr then
		error("Unsupported model lang:", impl.lang)
	end

	return cr(impl.file, impl.func, narg, argt, nret, rett)
end

return {
	create = create
}
