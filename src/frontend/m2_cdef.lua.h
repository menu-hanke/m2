//-- vim: ft=lua:
require("ffi").cdef [[
#define static_assert(...)

#include "../sim.h"
#include "../vec.h"
#include "../mem.h"
#include "../vmath.h"

#include "../fhk/fhk.h"
#include "../fhk/def.h"

#include "fhk/driver.h"

// not a clean solution, but luajit can't parse the definition..
#undef fhk_modcall
#define fhk_modcall void
#include "../fff/fff.h"
#include "../fff/lang.h"
]]
