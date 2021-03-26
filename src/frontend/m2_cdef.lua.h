//-- vim: ft=lua:
require("ffi").cdef [[
#define static_assert(...)

#include "../sim.h"
#include "../vec.h"
#include "../mem.h"
#include "../vmath.h"

#include "../model/model.h"
#include "../model/conv.h"
#include "../model/model_Const.h"
#include "../model/model_Lua.h"
#include "../model/model_R.h"

#include "../fhk/fhk.h"
#include "../fhk/def.h"

#include "fhk/driver.h"
]]
