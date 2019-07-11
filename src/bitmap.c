#include "bitmap.h"
#include "def.h"

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

bm8 *bm_alloc(size_t n){
	return aligned_alloc(M2_VECTOR_SIZE, VS(n));
}

void bm_free(bm8 *bm){
	free(bm);
}

void bm_zero(bm8 *bm, size_t n){
	memset(bm, 0, VS(n));
}

void bm_and(bm8 *bm, size_t n, uint8_t mask){
	n = VS(n);

	for(size_t i=0;i<n;i++)
		bm[i] &= mask;
}

void bm_and2(bm8 *restrict a, bm8 *restrict b, size_t n){
	// TODO: fastest way to do this is with _mm_and_ps()
	// (about 10-20% faster on my pc than this method, depending on bitmap size)

	n = VS(n);
	
	for(size_t i=0;i<n;i++)
		a[i] &= b[i];
}

void bm_or2(bm8 *restrict a, bm8 *restrict b, size_t n){
	// _mm_or_ps

	n = VS(n);

	for(size_t i=0;i<n;i++)
		a[i] |= b[i];
}
