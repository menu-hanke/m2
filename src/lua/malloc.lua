local ffi = require "ffi"

ffi.cdef [[
	void *malloc(size_t size);
	void free(void *ptr);
]]

return {
	new = function(ct, nelem)
		return ffi.cast(ct .. "*", ffi.C.malloc(ffi.sizeof(ct) * nelem))
	end
}
