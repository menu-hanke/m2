#include "model.h"
#include "conv.h"
#include "model_Lua.h"
#include "../def.h"

#include <stdlib.h>
#include <stdint.h>
#include <stdalign.h>
#include <string.h>
#include <lua.h>
#include <lualib.h>
#include <lauxlib.h>

struct mod_Lua {
	double *co;
	int handle;
	uint8_t n_co;
	struct mt_sig sig; // must be last
};

static lua_State *global_L = NULL;

#define MOD_REG_KEY   "m2.models"
static const char *LAZYLOAD_PROXY_F =
"return function(models, module, name) "                                                \
	"local handle = #models+1 "                                                         \
	"models[handle] = function(...) "                                                   \
		"local f = require(module)[name] or "                                           \
			"error(string.format([[module '%s' doesn't export '%s']], module, name))"   \
		"models[handle] = f "                                                           \
		"return f(...) "                                                                \
	"end "                                                                              \
	"return handle "                                                                    \
"end";

static lua_State *L_state();
static void L_setup(lua_State *L);
static int L_make_proxy(lua_State *L, const char *module, const char *name);
static void L_pushtable(lua_State *L, double *ds, size_t n);
static int L_nreadtable(lua_State *L, int idx, double *ds, size_t n, size_t retidx);

uint64_t mod_Lua_types(){
	return MT_sS(MT_DOUBLE);
}

struct mod_Lua *mod_Lua_create(const char *module, const char *func, struct mt_sig *sig,
		size_t n_co){

	// TODO: mt_sig_check sigille
	//if(!mt_sig_check(sig, mod_Lua_types()))
		//return NULL;

	// co -------------------------------------v
	// [struct mod_Lua] [    sig   ] [..pad..] [ co1 co2 ... coN ]

	size_t off_co = ALIGN(sizeof(struct mod_Lua) + MT_SIG_VA_SIZE(sig), alignof(double));
	struct mod_Lua *M = malloc(off_co + n_co*sizeof(double));
	M->n_co = n_co;
	M->co = ((void *)M) + off_co;
	M->handle = L_make_proxy(L_state(), module, func);
	mt_sig_copy(&M->sig, sig);

	return M;
}

void mod_Lua_calibrate(struct mod_Lua *M, double *co){
	memcpy(&M->co, co, M->n_co * sizeof(*co));
}

int mod_Lua_call(struct mod_Lua *M, mcall_s *mc){
	lua_State *L = global_L;
	lua_getfield(L, LUA_REGISTRYINDEX, MOD_REG_KEY); // [ models ]
	lua_rawgeti(L, -1, M->handle);                   // [ models, fp ]

	mt_type *typ = M->sig.typ;
	mcall_edge *edge = mc->edges;

	for(size_t i=0;i<M->sig.np;i++,typ++,edge++){
		if(UNLIKELY((*typ) & MT_SET)) // D
			L_pushtable(L, edge->p, edge->n);
		else           // d
			lua_pushnumber(L, *((double *)edge->p));
	}

	for(size_t i=0;i<M->n_co;i++)
		lua_pushnumber(L, M->co[i]);

	int res = lua_pcall(L, M->sig.np + M->n_co, M->sig.nr, 0);

	if(UNLIKELY(res)){
		model_errf("Lua error (%d): %s", res, lua_tostring(L, -1));
		lua_pop(L, 1);
		return MCALL_RUNTIME_ERROR;
	}

	int idx = -M->sig.nr;
	int ret = MCALL_OK;

	for(size_t i=0;i<M->sig.nr;i++,idx++,typ++,edge++){
		if(UNLIKELY((*typ) & MT_SET)) { // D
			if(UNLIKELY(ret = L_nreadtable(L, idx, edge->p, edge->n, i)))
				goto out;
		} else {
			int isnum;
			*((double *)edge->p) = lua_tonumberx(L, idx, &isnum);
			if(UNLIKELY(!isnum)){
				model_errf("Return value #%zu has invalid type (expected number, found %s)",
						i+1, lua_typename(L, lua_type(L, idx)));
				ret = MCALL_INVALID_RETURN;
				goto out;
			}
		}
	}

out:
	lua_pop(L, M->sig.nr + 1); // pop returns + model table
	return ret;
}

void mod_Lua_destroy(struct mod_Lua *M){
	lua_State *L = global_L;
	lua_getfield(L, LUA_REGISTRYINDEX, MOD_REG_KEY);
	lua_pushnil(L);
	lua_rawseti(L, -2, M->handle);     // models[M->handle] = nil
	lua_pop(L, 1);

	free(M);
}

void mod_Lua_cleanup(){
	if(global_L){
		lua_close(global_L);
		global_L = NULL;
	}
}

static lua_State *L_state(){
	if(UNLIKELY(!global_L)){
		dv("Lua: init model lua state\n");
		global_L = luaL_newstate();
		L_setup(global_L);
	}

	return global_L;
}

static void L_setup(lua_State *L){
	luaL_openlibs(L);

	lua_newtable(L);
	(void)luaL_dostring(L, LAZYLOAD_PROXY_F);
	lua_setfield(L, -2, "proxy");                    // models.proxy = ...
	lua_setfield(L, LUA_REGISTRYINDEX, MOD_REG_KEY); // registry[MOD_REG_KEY] = models
}

static int L_make_proxy(lua_State *L, const char *module, const char *name){
	lua_getfield(L, LUA_REGISTRYINDEX, MOD_REG_KEY);       // [ models ]
	lua_getfield(L, -1, "proxy");                          // [ models, proxy ]
	lua_insert(L, -2);                                     // [ proxy, models ]
	lua_pushstring(L, module);                             // [ proxy, models, module ]
	lua_pushstring(L, name);                               // [ proxy, models, module, name ]
	lua_call(L, 3, 1);                                     // [ handle ]
	int handle = lua_tointeger(L, -1);
	lua_pop(L, 1);
	return handle;
}

// [] -> [t]
static void L_pushtable(lua_State *L, double *ds, size_t n){
	lua_newtable(L);
	for(size_t i=1;i<=n;i++,ds++){
		lua_pushnumber(L, *ds);
		lua_rawseti(L, -2, i);      // t[i] = *ds
	}
}

static int L_nreadtable(lua_State *L, int idx, double *ds, size_t n, size_t retidx){
	int typ = lua_type(L, idx);
	if(UNLIKELY(typ != LUA_TTABLE)){
		model_errf("Return value #%zu has invalid type (expected table, found %s)",
				retidx+1, lua_typename(L, typ));
		return MCALL_INVALID_RETURN;
	}

	for(size_t i=1;i<=n;i++,ds++){
		int isnum;
		lua_rawgeti(L, idx, i);
		*ds = lua_tonumberx(L, -1, &isnum);

		if(UNLIKELY(!isnum)){
			model_errf("Return value #%zu[%zu] has invalid type (expexted number, found %s)",
					retidx+1, i, lua_typename(L, lua_type(L, -1)));
			lua_pop(L, 1);
			return MCALL_INVALID_RETURN;
		}

		lua_pop(L, 1);
	}

	return MCALL_OK;
}
