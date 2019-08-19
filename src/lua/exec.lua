local ffi = require "ffi"

ffi.metatype("ex_func", {
	__call = ffi.C.ex_exec,
	__gc = ffi.C.ex_destroy
})

local create_ex = {
	R     = ffi.C.ex_R_create,
	simoC = ffi.C.ex_simoC_create
}

local function promote_all(ts)
	local ret = ffi.new("ptype[?]", #ts)

	for i,t in ipairs(ts) do
		ret[i-1] = ffi.C.tpromote(t)
	end

	return ret, #ts
end

local function create(impl, argt, rett)
	local cr = create_ex[impl.lang]

	if not cr then
		error("Unsupported model lang:", impl.lang)
	end

	local argt, narg = promote_all(argt)
	local rett, nret = promote_all(rett)

	return cr(impl.file, impl.func, narg, argt, nret, rett)
end

local function from_model(m)
	local argt, rett = {}, {}

	for _,p in ipairs(m.params) do
		table.insert(argt, p.src.type)
	end

	for _,r in ipairs(m.returns) do
		table.insert(rett, r.src.type)
	end

	return create(m.impl, argt, rett)
end

return {
	create     = create,
	from_model = from_model
}
