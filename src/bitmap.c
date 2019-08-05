#include "bitmap.h"
#include "def.h"

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#define BITMAP_OP(n, step)\
	do{\
		size_t vs = BITMAP_SIZE(n);\
		for(size_t i=0;i<vs;i++){\
			step;\
		}\
	} while(0)

bm8 *bm_alloc(size_t n){
	return aligned_alloc(BITMAP_ALIGN, BITMAP_SIZE(n));
}

void bm_free(bm8 *bm){
	free(bm);
}

void bm_zero(bm8 *bm, size_t n){
	memset(bm, 0, BITMAP_SIZE(n));
}

void bm_copy(bm8 *restrict a, const bm8 *restrict b, size_t n){
	memcpy(a, b, BITMAP_SIZE(n));
}

void bm_and(bm8 *bm, size_t n, uint8_t mask){
	BITMAP_OP(n, bm[i] &= mask);
}

void bm_or(bm8 *bm, size_t n, uint8_t mask){
	BITMAP_OP(n, bm[i] |= mask);
}

void bm_xor(bm8 *bm, size_t n, uint8_t mask){
	BITMAP_OP(n, bm[i] ^= mask);
}

void bm_and2(bm8 *restrict a, const bm8 *restrict b, size_t n){
	BITMAP_OP(n, a[i] &= b[i]);
}

void bm_or2(bm8 *restrict a, const bm8 *restrict b, size_t n){
	BITMAP_OP(n, a[i] |= b[i]);
}

void bm_xor2(bm8 *restrict a, const bm8 *restrict b, size_t n){
	BITMAP_OP(n, a[i] ^= b[i]);
}

void bm_not(bm8 *bm, size_t n){
	bm_xor(bm, n, 0xff);
}

void bs_zero(bm8 *bs, size_t n){
	memset(bs, 0, BITSET_SIZE(n));
}

unsigned bs_get(bm8 *bs, size_t idx){
	uint64_t *u = (uint64_t *) bs;
	return (u[idx/64] >> (idx%64)) & ~1;
}

void bs_set(bm8 *bs, size_t idx){
	uint64_t *u = (uint64_t *) bs;
	u[idx/64] |= 1ULL << (idx%64);
}

void bs_clear(bm8 *bs, size_t idx){
	uint64_t *u = (uint64_t *) bs;
	u[idx/64] &= ~(1ULL << (idx%64));
}
