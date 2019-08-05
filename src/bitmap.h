#pragma once

#include "def.h"

#include <stdint.h>
#include <stddef.h>
#include <assert.h>

#define BITMAP_ALIGN   M2_VECTOR_SIZE
#define BITMAP_SIZE(n) VS(n)
#define BITSET_SIZE(n) BITMAP_SIZE(ALIGN((n), 8))
#define BITMAP(n)      [BITMAP_SIZE(n)] __attribute__((aligned(BITMAP_ALIGN)))
#define BITSET(n)      [BITSET_SIZE(n)] __attribute__((aligned(BITMAP_ALIGN)))

typedef uint8_t bm8 __attribute__((aligned(BITMAP_ALIGN)));

bm8 *bm_alloc(size_t n);
void bm_free(bm8 *bm);

void bm_zero(bm8 *bm, size_t n);
void bm_copy(bm8 *restrict a, const bm8 *restrict b, size_t n);
void bm_and(bm8 *bm, size_t n, uint8_t mask);
void bm_or(bm8 *bm, size_t n, uint8_t mask);
void bm_xor(bm8 *bm, size_t n, uint8_t mask);
void bm_and2(bm8 *restrict a, const bm8 *restrict b, size_t n);
void bm_or2(bm8 *restrict a, const bm8 *restrict b, size_t n);
void bm_xor2(bm8 *restrict a, const bm8 *restrict b, size_t n);
void bm_not(bm8 *bm, size_t n);

void bs_zero(bm8 *bs, size_t n);
unsigned bs_get(bm8 *bs, size_t idx);
void bs_set(bm8 *bs, size_t idx);
void bs_clear(bm8 *bs, size_t idx);

// can't have bm8 here as an union member because of the alignment
#define BMU8(...) { uint8_t u8;\
	struct __VA_ARGS__ __attribute__((packed));\
	static_assert(sizeof(struct __VA_ARGS__ __attribute__((packed))) == 1); }
