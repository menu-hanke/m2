#pragma once

#include "model.h"
#include "conv.h"

#include <stdint.h>

typedef struct mod_Lua mod_Lua;

uint64_t mod_Lua_types();
mod_Lua *mod_Lua_create(const char *module, const char *func, struct mt_sig *sig);
mod_Lua *mod_LuaJIT_create(const char *module, const char *func, struct mt_sig *sig);
void mod_Lua_calibrate(mod_Lua *m, size_t n_co, double *co);
int mod_Lua_call(mod_Lua *m, mcall_s *mc);
void mod_Lua_destroy(mod_Lua *m);
void mod_Lua_cleanup();
