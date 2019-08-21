local ffi = require "ffi"

local arena = {
	reset  = ffi.C.arena_reset,
	alloc  = ffi.C.arena_alloc,
	malloc = ffi.C.arena_malloc,

	new    = function(self, ct)
		return ffi.cast(ct, self:alloc(ffi.sizeof(ct), ffi.alignof(ct)))
	end
}

ffi.metatype("arena", {
	__index = arena
	--__gc    = ffi.C.arena_destroy
})

return {
	create = function(sz)
		return ffi.C.arena_create(sz or 2048)
	end,
	create_gc = function(sz)
		return ffi.gc(ffi.C.arena_create(sz or 2048), ffi.C.arena_destroy)
	end
}
