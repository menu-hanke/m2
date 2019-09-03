local ffi = require "ffi"

ffi.cdef [[
	void *malloc(size_t size);
	void free(void *ptr);
]]

-- This is mainly useful for allocating long-living cdata that need to be referenced from C,
-- since gc will move cdata allocated with ffi.new
local function malloc_ctype(ct, nelem)
	nelem = nelem or 1
	return ffi.cast(ct .. "*", ffi.C.malloc(ffi.sizeof(ct) * nelem))
end

return {
	new_nogc = malloc_ctype,
	new = function(ct, nelem)
		return ffi.gc(malloc_ctype(ct, nelem), ffi.C.free)
	end
}
