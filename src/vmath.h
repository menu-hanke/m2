#pragma once

#include "def.h"

typedef float vf32 __attribute__((aligned(M2_VECTOR_SIZE)));
typedef double vf64 __attribute__((aligned(M2_VECTOR_SIZE)));

void vadd_f64(vf64 *a, size_t n, double c);
void vadd2_f64(vf64 *restrict a, const vf64 *restrict b, size_t n);
