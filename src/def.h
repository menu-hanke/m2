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
#define DD(x) ((void)0)
#define UNREACHABLE() __builtin_unreachable()

#endif // ifdef DEBUG

#ifndef M2_VECTOR_SIZE

// avx512 -> 64
// avx -> 32
// sse -> 16
// otherwise -> 8

#if defined(__AVX__)
#define M2_VECTOR_SIZE 32
#else
#define M2_VECTOR_SIZE 16
#endif

#endif // ifndef M2_VECTOR_SIZE

// vector size for n bytes
#define VS(n) (((n) + M2_VECTOR_SIZE - 1) & ~(M2_VECTOR_SIZE - 1))

// vector elements for n bytes
#define VN(n) (VS(n) / M2_VECTOR_SIZE)

// when building a release set this to /usr/lib/something etc (from makefile).
#ifndef M2_LUAPATH
#define M2_LUAPATH "src/lua"
#endif

#ifdef EXPORT_LUA_CDEF
#define EXPORT_LUA
#define EXL @@export@@
#else
#define EXPORT_LUA
#define EXL
#endif
