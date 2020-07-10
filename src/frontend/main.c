#include <stdlib.h>
#include <string.h>
#include <lua.h>
#include <lualib.h>
#include <lauxlib.h>

// when building a release set this to /usr/lib/something etc (from makefile).
#ifndef M2_LUAPATH
#define M2_LUAPATH "src/frontend"
#endif

#define M2_LUASEARCHPATH  M2_LUAPATH"/?.lua"
#define M2_MAINFILE       M2_LUAPATH"/m2.lua"

static void l_push_args(lua_State *L, int argc, char **argv);
static int l_main(lua_State *L, int argc, char **argv);

static int L_traceback(lua_State *L);

int main(int argc, char **argv){
	lua_State *L = luaL_newstate();
	luaL_openlibs(L);
	return l_main(L, argc, argv);
}

static void l_push_args(lua_State *L, int argc, char **argv){
	lua_newtable(L);
	for(int i=1;i<=argc;i++,argv++){
		lua_pushinteger(L, i);
		lua_pushstring(L, *argv);
		lua_settable(L, -3);
	}
}

static int l_main(lua_State *L, int argc, char **argv){
	lua_pushcfunction(L, L_traceback);
	int msgh = lua_gettop(L);

	if(luaL_dofile(L, M2_MAINFILE)){
		fprintf(stderr, "Lua error: %s\n", lua_tostring(L, -1));
		return -1;
	}

	lua_getfield(L, -1, "bootstrap");
	lua_pushliteral(L, M2_LUASEARCHPATH);
	if(lua_pcall(L, 1, 0, msgh)){
		fprintf(stderr, "bootstrap: Lua error %s\n", lua_tostring(L, -1));
		return -1;
	}

	lua_getfield(L, -1, "main");
	l_push_args(L, argc, argv);
	if(lua_pcall(L, 1, 1, msgh)){
		fprintf(stderr, "Lua error: %s\n", lua_tostring(L, -1));
		return -1;
	}

	int ret = lua_tointeger(L, -1);
	lua_close(L);
	return ret;
}

static int L_traceback(lua_State *L){
	luaL_traceback(L, L, lua_tostring(L, 1), 1);
	return 1;
}
