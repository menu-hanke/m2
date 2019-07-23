#pragma once

#ifdef DEBUG

#include <stdio.h>
#include <assert.h>
#define dd(...) fprintf(stderr, __VA_ARGS__)
#define dv(fmt, ...) dd("%s@%-20s" fmt, __FILE__, __func__, ##__VA_ARGS__)
#define DD(x) x
#define UNREACHABLE() assert(!"unreachable")

#else

#define dd(...) ((void)0)
#define dv(...) ((void)0)
#define DD(x)
#define UNREACHABLE() __builtin_unreachable()

#endif // ifdef DEBUG

#ifndef M2_VECTOR_SIZE

/* TODO there should be some smarter logic to detect this
 * (or just set it when running make.)
 * Setting the largest possible isn't always a good idea */
#define M2_VECTOR_SIZE 16

#endif // ifndef M2_VECTOR_SIZE

// round n to next multiple of m where m=2^k
#define ALIGN(n, m) (((n) + (m) - 1) & ~((m) - 1))

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
#define SIM_MAX_DEPTH 8
#endif

// size for the initial chunk for the sims memory arena
// (these are allocated per stack level)
#ifndef SIM_ARENA_SIZE
#define SIM_ARENA_SIZE 8096
#endif
