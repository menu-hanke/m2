#include "def.h"

#include <stdlib.h>
#include <string.h>
#include <lua.h>
#include <lualib.h>
#include <lauxlib.h>

#define M2_LUASEARCHPATH  M2_LUAPATH"/?.lua"
#define M2_MAINFILE       M2_LUAPATH"/m2.lua"
#define M2_MAIN           "main"

static void l_setup_path(lua_State *L);
static void l_push_args(lua_State *L, int argc, char **argv);
static int l_main(lua_State *L, int argc, char **argv);

static int L_traceback(lua_State *L);

int main(int argc, char **argv){
	lua_State *L = luaL_newstate();
	luaL_openlibs(L);
	return l_main(L, argc, argv);
}

static void l_setup_path(lua_State *L){
	lua_getglobal(L, "package");
	lua_getfield(L, -1, "path");
	size_t pathlen;
	const char *path = lua_tolstring(L, -1, &pathlen);
	char *newpath = malloc(strlen(M2_LUASEARCHPATH) + 1 + pathlen + 1);
	sprintf(newpath, "%s;%s", M2_LUASEARCHPATH, path);
	lua_pushstring(L, newpath);
	lua_setfield(L, -3, "path");
	lua_pop(L, 2);
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
	l_setup_path(L);

	if(luaL_dofile(L, M2_MAINFILE)){
		fprintf(stderr, "Lua error: %s\n", lua_tostring(L, -1));
		return -1;
	}

	lua_pushcfunction(L, L_traceback);
	int msgh = lua_gettop(L);

	lua_getglobal(L, M2_MAIN);
	l_push_args(L, argc, argv);

	if(lua_pcall(L, 1, 1, msgh)){
		fprintf(stderr, "Lua error: %s\n", lua_tostring(L, -1));
		return -2;
	}

	int ret = lua_tointeger(L, -1);

	lua_close(L);
	return ret;
}

static int L_traceback(lua_State *L){
	luaL_traceback(L, L, lua_tostring(L, 1), 1);
	return 1;
}
