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

#define LIKELY(x)   __builtin_expect(!!(x), 1)
#define UNLIKELY(x) __builtin_expect(!!(x), 0)

#ifndef M2_VECTOR_SIZE

/* TODO there should be some smarter logic to detect this
 * (or just set it when running make.)
 * Setting the largest possible isn't always a good idea */
#define M2_VECTOR_SIZE 16
#define M2_SIMD_ALIGN  M2_VECTOR_SIZE

#endif // ifndef M2_VECTOR_SIZE

// round n to next multiple of m where m=2^k
#define ALIGN(n, m) ((typeof(n)) (((uintptr_t)(n) + (m) - 1) & ~((m) - 1)))

// vector size for n bytes
#define VS(n) ALIGN((n), M2_VECTOR_SIZE)

// *** simulator config ***

// max branching depth for the simulator
#ifndef SIM_MAX_DEPTH
#define SIM_MAX_DEPTH 16
#endif

// virtual memory to allocate per sim region
#ifndef SIM_REGION_SIZE
#define SIM_REGION_SIZE 0x10000000ULL
#endif
