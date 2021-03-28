#pragma once

#define FFF_0(...)
#define FFF_1(...) __VA_ARGS__
#define FFF___opt(x,...) FFF_##x(__VA_ARGS__)
#define FFF__opt(vm,...) FFF___opt(vm, __VA_ARGS__)
#define FFF_opt(vm,...) FFF__opt(FFF_##vm,__VA_ARGS__)

typedef char fff_empty[0];

#define FFF_vmdef(_) \
	FFF_opt(Lua, _(Lua, void *))    \
	FFF_opt(R,   _(R,   void *))

// --------------------------------------------------------------------------------

#ifndef FFF_Lua
#define FFF_Lua 0
#endif

#ifndef FFF_R
#define FFF_R 0
#endif

// --------------------------------------------------------------------------------

#if FFF_Lua
#include "ff_Lua.h"
void fffLua_destroy(fff_state *F);
#endif

#if FFF_R
#include "ff_R.h"
void fffR_destroy(fff_state *F);
#endif
