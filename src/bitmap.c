#include "bitmap.h"
#include "def.h"

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

static bm8 broadcast(uint8_t mask);

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
	n = VN(n);
	bm8 m = broadcast(mask);

	for(size_t i=0;i<n;i++)
		bm[i] &= m;
}

static bm8 broadcast(uint8_t mask){
	bm8 ret = {0};
	ret += mask;
	return ret;
}
