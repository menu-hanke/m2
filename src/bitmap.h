#pragma once

#include "def.h"

#include <stdint.h>
#include <stddef.h>
#include <assert.h>

typedef uint8_t bm8 __attribute__((aligned(M2_VECTOR_SIZE)));

bm8 *bm_alloc(size_t n);
void bm_free(bm8 *bm);

void bm_zero(bm8 *bm, size_t n);
void bm_and(bm8 *bm, size_t n, uint8_t mask);
void bm_and2(bm8 *restrict a, bm8 *restrict b, size_t n);
void bm_or2(bm8 *restrict a, bm8 *restrict b, size_t n);

// can't have bm8 here as an union member because of the alignment
#define BMU8(...) { uint8_t u8;\
	struct __VA_ARGS__ __attribute__((packed));\
	static_assert(sizeof(struct __VA_ARGS__ __attribute__((packed))) == 1); }
