#pragma once

#include <stdio.h>

#ifdef DEBUG

#include <assert.h>
#define dd(...) fprintf(stderr, __VA_ARGS__)
#define dv(fmt, ...) dd("(%-12s) %-19s " fmt, __FILE__, __func__, ##__VA_ARGS__)
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

// round n to next multiple of m where m=2^k
#include <stdint.h>
#define ALIGN(n, m) ((typeof(n)) (((uintptr_t)(n) + (m) - 1) & ~((uintptr_t)(m) - 1)))

// vector size for n bytes
#define VS(n) ALIGN((n), M2_VECTOR_SIZE)
