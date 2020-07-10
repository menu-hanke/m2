-- type conversion rules for the model ffi.
-- these follow mostly C rules but with a few extra types.
--
-- TODO? if needed later:
--     * udata pointers - just pass the pointer, no conversion
--     * aggregates (struct/union) - passing a pointer should be easy, works at least for luajit
--       ffi and C (though luajit ffi needs some workarounds since the ffi isn't available via the
--       C api)
--     * dicts/sets/lists - idk?
--     * strings - probably need to pass pointers through fhk, memcpy from model memory to driver
--       so that either the driver or simulator owns the strings (same with dict/set/list case)

local int_mt = { __index={} }

local function int(signed, size)

end
