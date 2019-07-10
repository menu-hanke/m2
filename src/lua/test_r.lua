local ffi = require "ffi"

ffi.cdef [[
int setenv(const char *name, const char *value, int overwrite);
]]

local function main(args)
	ffi.C.setenv("R_HOME", "/usr/lib64/R", 0)

	local argt = ffi.new("enum ptype[2]")
	local rett = ffi.new("enum ptype[1]")
	argt[0] = ffi.C.T_REAL
	argt[1] = ffi.C.T_REAL
	rett[0] = ffi.C.T_REAL

	local ex = ffi.C.ex_R_create(
		"examples/models1.r",
		"M1",
		2, argt,
		1, rett
	)

	local args = ffi.new("union pvalue[2]")
	local res = ffi.new("union pvalue[1]")
	args[0].r = 100
	args[1].r = 2
	ffi.C.ex_R_exec(ex, res, args)

	print("got: " .. tonumber(res[0].r))

	ffi.C.ex_R_destroy(ex)
end

return {
	main=main
}
