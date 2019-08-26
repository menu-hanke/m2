#pragma once

#include <stdio.h>

#ifdef DEBUG

#include <assert.h>
#define dd(...) fprintf(stderr, __VA_ARGS__)
#define dv(fmt, ...) dd("(%-12s) %-20s" fmt, __FILE__, __func__, ##__VA_ARGS__)
#define DD(x) x
#define UNREACHABLE() assert(!"unreachable")

#else

#define dd(...) ((void)0)
#define dv(...) ((void)0)
#define DD(x)
#define UNREACHABLE() __builtin_unreachable()

#endif // ifdef DEBUG

#define DIEF(err, fmt, mes)\
	do{ fprintf(stderr, "Fatal error: "); fprintf(stderr, (fmt), (mes)); exit(err); } while(0)

#ifndef M2_VECTOR_SIZE

/* TODO there should be some smarter logic to detect this
 * (or just set it when running make.)
 * Setting the largest possible isn't always a good idea */
#define M2_VECTOR_SIZE 16

#endif // ifndef M2_VECTOR_SIZE

// round n to next multiple of m where m=2^k
#define ALIGN(n, m) (((n) + (m) - 1) & ~((m) - 1))

#define ASSUME_ALIGNED(x, m)\
	do {\
		assert((x) == ALIGN((x), (m)));\
		if((x) != ALIGN((x), (m)))\
			__builtin_unreachable();\
	} while(0)

// vector size for n bytes
#define VS(n) ALIGN((n), M2_VECTOR_SIZE)

// when building a release set this to /usr/lib/something etc (from makefile).
#ifndef M2_LUAPATH
#define M2_LUAPATH "src/lua"
#endif

#ifdef EXPORT_LUA_CDEF
// luajit doesn't parse these so remove them when exporting cdefs
#define static_assert(...) @@remove@@
#endif

// *** simulator config ***

// max branching depth for the simulator
#ifndef SIM_MAX_DEPTH
#define SIM_MAX_DEPTH 16
#endif

// size for the initial chunk for the sims memory arena
// (these are allocated per stack level)
#ifndef SIM_ARENA_SIZE
#define SIM_ARENA_SIZE 8096
#endif

// max size for save stack
#ifndef SIM_VSTACK_SIZE
#define SIM_VSTACK_SIZE (1 << 16)
#endif

// size for initial chunk of static arena
// this should be a few times bigger than SIM_SAVE_STACK_SIZE since the save stack
// and each frame's copy of the save stack is allocated on the static arena
// (Note: 2^20 = around 1 Mb)
#ifndef SIM_STATIC_ARENA_SIZE
#define SIM_STATIC_ARENA_SIZE (1 << 20)
#endif

// max number of vars in an object
// Note: this must be a multiple of 8*M2_VECTOR_SIZE!
#ifndef SIM_MAX_VAR
#define SIM_MAX_VAR (8*M2_VECTOR_SIZE)
#endif

// initial temp stack chunk size
#ifndef SIM_TMP_ARENA_SIZE
#define SIM_TMP_ARENA_SIZE 8096
#endif

// init vector size for object vectors
// Note: this must be a multiple of M2_VECTOR_SIZE!
#ifndef WORLD_INIT_VEC_SIZE
#define WORLD_INIT_VEC_SIZE 128
#endif
