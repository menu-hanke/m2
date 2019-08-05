#pragma once

#include "def.h"

#include <stddef.h>

typedef float vf32 __attribute__((aligned(M2_VECTOR_SIZE)));
typedef double vf64 __attribute__((aligned(M2_VECTOR_SIZE)));

void vset_f64(vf64 *d, double c, size_t n);
void vadd_f64s(vf64 *d, vf64 *a, double c, size_t n);
void vadd_f64v(vf64 *d, vf64 *a, const vf64 *restrict b, size_t n);
