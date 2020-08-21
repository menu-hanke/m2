#include "model.h"
#include "conv.h"
#include "model_Lua.h"
#include "../def.h"

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>
#include <string.h>
#include <assert.h>

#include <lua.h>
#include <lualib.h>
#include <lauxlib.h>

// TODO: to implement coefficients: the coeff array lives in ffi memory (maybe even inline
// them in the wrapper to get free constant folding). wrapper will provide a function to
// regenerate/recalibrate.

// why pass around a pointer when you can just pass the handle
typedef uintptr_t handle;
#define TOHANDLE(m)   ((handle) (m))
#define FROMHANDLE(h) ((mod_Lua *) (h))

static const char LOADER[] = {
#include "loader.lua.in"
};

// these asserts would belong in loader.lua.h, but luajit doesn't have a nice way to
// do them because mcall_edge isn't a real struct
static_assert(offsetof(mcall_edge, p) == 0
		&& offsetof(mcall_edge, n) == sizeof(void *));
static_assert(offsetof(struct mt_sig, np) == 0
		&& offsetof(struct mt_sig, nr) == 1
		&& offsetof(struct mt_sig, typ) == 2
		&& sizeof(struct mt_sig) == 2);

#define K_MODELS   "m2.models"
#define K_PROXY    "m2.proxy"

// we could make this thread safe by allowing the user to create multiple lua_States, but
// other model callers (eg. R) aren't and can't be made thread safe either, so it's easier
// to have none of them be thread safe.
static lua_State *global_L = NULL;

static void init_L();
static handle make_proxy(const char *mod_or_bc, size_t n, const char *name, struct mt_sig *sig,
		const char *mode);

uint64_t mod_Lua_types(){
	return ~0ULL;
}

mod_Lua *mod_Lua_create(const char *module, const char *func, struct mt_sig *sig){
	return FROMHANDLE(make_proxy(module, strlen(module), func, sig, "lua"));
}

mod_Lua *mod_LuaJIT_create(const char *module, const char *func, struct mt_sig *sig){
	return FROMHANDLE(make_proxy(module, strlen(module), func, sig, "ffi"));
}

mod_Lua *mod_LuaBC_create(const char *buf, size_t sz, const char *name, struct mt_sig *sig){
	return FROMHANDLE(make_proxy(buf, sz, name, sig, "bc"));
}

void mod_Lua_calibrate(mod_Lua *M, size_t n_co, double *co){
	(void)M;
	(void)n_co;
	(void)co;
	assert(!"TODO");
}

int mod_Lua_call(mod_Lua *M, mcall_s *mc){
	lua_State *L = global_L;
	lua_getfield(L, LUA_REGISTRYINDEX, K_MODELS);
	lua_rawgeti(L, -1, TOHANDLE(M));
	lua_pushlightuserdata(L, mc);

	int res = lua_pcall(L, 1, 0, 0);

	if(UNLIKELY(res)){
		model_errf("Lua error (%d): %s", res, lua_tostring(L, -1));
		lua_pop(L, 2);
		return MCALL_RUNTIME_ERROR;
	}

	lua_pop(L, 1);
	return MCALL_OK;
}

void mod_Lua_destroy(mod_Lua *M){
	lua_State *L = global_L;
	lua_getfield(L, LUA_REGISTRYINDEX, K_MODELS);
	lua_pushnil(L);
	lua_rawseti(L, -2, TOHANDLE(M));     // models[M->handle] = nil
	lua_pop(L, 1);
}

void mod_Lua_cleanup(){
	if(global_L){
		lua_close(global_L);
		global_L = NULL;
	}
}

static void init_L(){
	if(LIKELY(global_L))
		return;

	global_L = luaL_newstate();
	luaL_openlibs(global_L);
	(void)luaL_dostring(global_L, LOADER);
	assert(lua_type(global_L, -2) == LUA_TTABLE && lua_type(global_L, -1) == LUA_TFUNCTION);
	lua_setfield(global_L, LUA_REGISTRYINDEX, K_PROXY);
	lua_setfield(global_L, LUA_REGISTRYINDEX, K_MODELS);
}

// this can't fail, because the loading is deferred until first call
static handle make_proxy(const char *mod_or_bc, size_t n, const char *name, struct mt_sig *sig,
		const char *mode){

	init_L();
	lua_getfield(global_L, LUA_REGISTRYINDEX, K_PROXY);
	lua_pushlstring(global_L, mod_or_bc, n);
	lua_pushstring(global_L, name);
	lua_pushlightuserdata(global_L, sig);
	lua_pushstring(global_L, mode);
	lua_call(global_L, 4, 1);
	handle h = lua_tointeger(global_L, -1);
	lua_pop(global_L, 1);
	return h;
}
