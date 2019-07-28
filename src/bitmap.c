#include "bitmap.h"
#include "def.h"

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#define BITMAP_OP(n, step)\
	do{\
		size_t vs = VS(n);\
		for(size_t i=0;i<vs;i++){\
			step;\
		}\
	} while(0)

bm8 *bm_alloc(size_t n){
	return aligned_alloc(BITMAP_ALIGN, VS(n));
}

void bm_free(bm8 *bm){
	free(bm);
}

void bm_zero(bm8 *bm, size_t n){
	memset(bm, 0, VS(n));
}

void bm_copy(bm8 *restrict a, const bm8 *restrict b, size_t n){
	memcpy(a, b, VS(n));
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
