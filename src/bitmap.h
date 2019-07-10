#pragma once

#include "def.h"

#include <stdint.h>
#include <stddef.h>

typedef uint8_t bm8 __attribute__((vector_size(M2_VECTOR_SIZE)));

bm8 *bm_alloc(size_t n);
void bm_free(bm8 *bm);

void bm_zero(bm8 *bm, size_t n);
void bm_and(bm8 *bm, size_t n, uint8_t mask);

#define BM_U8(bm) (*((uint8_t *) (bm)))
