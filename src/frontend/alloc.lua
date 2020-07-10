local ffi = require "ffi"

ffi.cdef [[
	void *malloc(size_t size);
	void free(void *ptr);
]]

local function cts(ct, cp)
	ct = type(ct) == "string" and ffi.typeof(ct) or ct
	cp = cp or ffi.typeof("$ *", ct)
	return ct, cp
end

ffi.metatype("arena", { __index = {
	reset   = ffi.C.arena_reset,
	destroy = ffi.C.arena_destroy,
	alloc   = ffi.C.arena_alloc,
	malloc  = ffi.C.arena_malloc,
	new     = function(self, ct, ne, cp)
		if ne == 0 then return end
		ct, cp = cts(ct, cp)
		return ffi.cast(cp, self:alloc(ffi.sizeof(ct) * (ne or 1), ffi.alignof(ct)))
	end
}})

local function malloc(ct, ne, cp)
	if ne == 0 then return end
	ct, cp = cts(ct, cp)
	return ffi.cast(cp, ffi.C.malloc(ffi.sizeof(ct) * (ne or 1)))
end

return {
	arena = function(sz) return ffi.gc(ffi.C.arena_create(sz or 2000), ffi.C.arena_destroy) end,
	arena_nogc = function(sz) return ffi.C.arena_create(sz or 2000) end,
	malloc = function(ct, ne, cp) return ffi.gc(malloc(ct, ne, cp), ffi.C.free) end,
	malloc_nogc = malloc
}
