//-- vim: ft=lua:
require("ffi").cdef [[
#define static_assert(...)

#include "../sim.h"
#include "../vec.h"
#include "../grid.h"
#include "../vgrid.h"
#include "../mem.h"
#include "../vmath.h"

#include "../model/all.h"

#include "../fhk/fhk.h"
#include "../fhk/graph.h"

#include "fhk/driver.h"
]]
