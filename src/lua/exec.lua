local ffi = require "ffi"

local function promote_all(ts)
	local ret = ffi.new("ptype[?]", #ts)

	for i,t in ipairs(ts) do
		ret[i-1] = ffi.C.tpromote(t)
	end

	return ret, #ts
end

local function destroy(f)
	f.impl.destroy(f)
end

local function exec(f, ret, args)
	return f.impl.exec(f, ret, args)
end

local function create(impl, argt, rett)
	if impl.lang ~= "R" then
		error("sorry only R")
	end

	local argt, narg = promote_all(argt)
	local rett, nret = promote_all(rett)

	return ffi.gc(ffi.C.ex_R_create(
		impl.file, impl.func,
		narg, argt,
		nret, rett
	), destroy)
end

local function from_model(m)
	local argt = {}

	for _,p in ipairs(m.params) do
		table.insert(argt, p.src.type)
	end

	local rett = { m.returns.src.type }
	return create(m.impl, argt, rett)
end

return {
	create     = create,
	from_model = from_model,
	destroy    = destroy,
	exec       = exec
}
