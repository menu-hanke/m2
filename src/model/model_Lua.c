#include "model_Lua.h"
#include "../def.h"

#include <stdlib.h>
#include <stdint.h>
#include <lua.h>
#include <lualib.h>
#include <lauxlib.h>

struct model_Lua {
	struct model model;
	enum mod_Lua_calib_mode mode;
};

#define MADDR(m) ((void *) &(m)->model)
#define CADDR(m) ((void *) &(m)->mode)
#define GETREG(p) do{ lua_pushlightuserdata(L, (p)); lua_gettable(L, LUA_REGISTRYINDEX); } while(0)

static lua_State *L = NULL;

static int mod_Lua_call(struct model_Lua *m, pvalue *ret, pvalue *argv);
static void mod_Lua_calibrate(struct model_Lua *m);
static void mod_Lua_destroy(struct model_Lua *m);

static const struct model_func MOD_LUA = {
	.call      = (model_call_f) mod_Lua_call,
	.calibrate = (model_calibrate_f) mod_Lua_calibrate,
	.destroy   = (model_destroy_f) mod_Lua_destroy
};

static void init_lua_state();
static int require(const char *module);
static int pcall(int narg, int nres);

model *mod_Lua_create(struct mod_Lua_def *def){
	init_lua_state();

	if(require(def->module))
		return NULL;

	struct model_Lua *m = malloc(sizeof *m);
	maux_initmodel(&m->model,
			&MOD_LUA,
			def->n_arg, def->atypes,
			def->n_ret, def->rtypes,
			def->n_coef, def->flags
	);

	m->mode = def->mode;

	lua_pushlightuserdata(L, MADDR(m));
	lua_getglobal(L, def->func);
	lua_settable(L, LUA_REGISTRYINDEX);

	return (model *) m;
}

static int mod_Lua_call(struct model_Lua *m, pvalue *ret, pvalue *argv){
	maux_exportd(&m->model, argv);

	GETREG(MADDR(m));
	// stack: f

	for(unsigned i=0;i<m->model.n_arg;i++)
		lua_pushnumber(L, argv[i].f64);
	// stack: f arg1 ... argn
	
	unsigned narg = m->model.n_arg;

	if(MODEL_ISCALIBRATED(&m->model)){
		if(m->mode == MOD_LUA_EXPAND){
			narg += m->model.n_coef;
			for(unsigned i=0;i<m->model.n_coef;i++)
				lua_pushnumber(L, m->model.coefs[i]);
			// stack: f arg1 ... argn c1 ... cm
		}else{ // mode == MOD_LUA_PASS_TABLE
			narg++;
			GETREG(CADDR(m));
			// stack: f arg1 ... argn ctable
		}
	}

	int r = pcall(narg, m->model.n_ret);
	if(r)
		return MODEL_CALL_RUNTIME_ERROR;

	int idx = -m->model.n_ret;
	for(unsigned i=0;i<m->model.n_ret;i++,idx++){
		int isnum;
		ret[i].f64 = lua_tonumberx(L, idx, &isnum);

		if(!isnum){
			int t = lua_type(L, idx);
			maux_errf("Invalid return type of return value %d, got %s, expected number",
					-idx, lua_typename(L, t));
			r = MODEL_CALL_INVALID_RETURN;
			goto out;
		}
	}

	maux_importd(&m->model, ret);

out:
	lua_pop(L, m->model.n_ret);
	return r;
}

static void mod_Lua_calibrate(struct model_Lua *m){
	if(m->mode == MOD_LUA_PASS_TABLE){
		// reg[CADDR(m)] = { c1, ..., cn }

		lua_pushlightuserdata(L, CADDR(m));

		lua_createtable(L, m->model.n_coef, 0);
		for(unsigned i=0;i<m->model.n_coef;i++){
			lua_pushnumber(L, m->model.coefs[i]);
			lua_rawseti(L, -2, i+1);
		}

		lua_settable(L, LUA_REGISTRYINDEX);
	}
}

static void mod_Lua_destroy(struct model_Lua *m){
	lua_pushlightuserdata(L, MADDR(m));
	lua_pushnil(L);
	lua_settable(L, LUA_REGISTRYINDEX);

	lua_pushlightuserdata(L, CADDR(m));
	lua_pushnil(L);
	lua_settable(L, LUA_REGISTRYINDEX);
}

static void init_lua_state(){
	if(L)
		return;

	dv("Lua: init model lua state\n");
	L = luaL_newstate();
	luaL_openlibs(L);
}

static int require(const char *module){
	dv("Lua: require %s\n", module);
	lua_getglobal(L, "require");
	lua_pushstring(L, module);
	return pcall(1, 0);
}

static int pcall(int narg, int nres){
	int r = lua_pcall(L, narg, nres, 0);

	if(r){
		maux_errf("Lua error (%d): %s", r, lua_tostring(L, -1));
		lua_pop(L, 1);
	}

	return r;
}
