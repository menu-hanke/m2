#pragma once

#include "aux.h"

enum mod_Lua_calib_mode {
	MOD_LUA_EXPAND,
	MOD_LUA_PASS_TABLE
	/* TODO: pass args/coefs by name in a table */
};

struct mod_Lua_def {
	MODEL_INIT_DEF;
	const char *module;
	const char *func;
	unsigned n_coef;
	enum mod_Lua_calib_mode mode;
};

model *mod_Lua_create(struct mod_Lua_def *def);
