#include "bitmap.h"
#include "def.h"

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

typedef uint64_t alias64 __attribute__((may_alias, aligned(BITMAP_ALIGN)));
#define b64(bm) ((alias64 *) (bm))

#define BITMAP_OP(n, step)\
	do{\
		size_t vs = BITMAP_SIZE(n);\
		for(size_t i=0;i<vs;i++){\
			step;\
		}\
	} while(0)

#define BITMAP_OP64(n, step) BITMAP_OP(ALIGN((n), sizeof(uint64_t)/sizeof(uint64_t)), step)

bm8 *bm_alloc(size_t n){
	return aligned_alloc(BITMAP_ALIGN, BITMAP_SIZE(n));
}

void bm_free(bm8 *bm){
	free(bm);
}

void bm_set64(bm8 *bm, size_t n, uint64_t c){
	BITMAP_OP64(n, b64(bm)[i] = c);
}

void bm_zero(bm8 *bm, size_t n){
	bm_set64(bm, n, 0);
}

void bm_copy(bm8 *restrict a, const bm8 *restrict b, size_t n){
	memcpy(a, b, BITMAP_SIZE(n));
}

void bm_and64(bm8 *bm, size_t n, uint64_t mask){
	BITMAP_OP64(n, b64(bm)[i] &= mask);
}

void bm_or64(bm8 *bm, size_t n, uint64_t mask){
	BITMAP_OP64(n, b64(bm)[i] |= mask);
}

void bm_xor64(bm8 *bm, size_t n, uint64_t mask){
	BITMAP_OP64(n, b64(bm)[i] ^= mask);
}

void bm_and(bm8 *restrict a, const bm8 *restrict b, size_t n){
	BITMAP_OP(n, a[i] &= b[i]);
}

void bm_or(bm8 *restrict a, const bm8 *restrict b, size_t n){
	BITMAP_OP(n, a[i] |= b[i]);
}

void bm_xor(bm8 *restrict a, const bm8 *restrict b, size_t n){
	BITMAP_OP(n, a[i] ^= b[i]);
}

void bm_not(bm8 *bm, size_t n){
	bm_xor64(bm, n, ~0);
}

void bs_zero(bm8 *bs, size_t n){
	memset(bs, 0, BITSET_SIZE(n));
}

unsigned bs_get(bm8 *bs, size_t idx){
	return (b64(bs)[idx/64] >> (idx%64)) & ~1;
}

void bs_set(bm8 *bs, size_t idx){
	b64(bs)[idx/64] |= 1ULL << (idx%64);
}

void bs_clear(bm8 *bs, size_t idx){
	b64(bs)[idx/64] &= ~(1ULL << (idx%64));
}

uint64_t bmask8(uint8_t mask8){
	uint16_t mask16 = mask8;
	return bmask16(mask16 | (mask16 << 8));
}

uint64_t bmask16(uint16_t mask16){
	uint32_t mask32 = mask16;
	return bmask32(mask32 | (mask32 << 16));
}

uint64_t bmask32(uint32_t mask32){
	uint64_t mask64 = mask32;
	return mask64 | (mask64 << 32);
}

