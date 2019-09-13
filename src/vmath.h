#pragma once

#include "def.h"

#include <stddef.h>
#include <stdint.h>

typedef M2_VECTOR_REAL vreal;
typedef M2_VECTOR_MASK vmask;

void vsetc(vreal *d, vreal c, size_t n);
void vaddc(vreal *d, vreal *a, vreal c, size_t n);
void vaddv(vreal *d, vreal *a, const vreal *restrict b, size_t n);
void vsorti(unsigned *i, vreal *a, size_t n);
vreal vsum(vreal *a, size_t n);
vreal vsumm(vreal *a, vmask *m, vmask mask, size_t n);
void vpsumi(vreal *d, const vreal *restrict a, unsigned *idx, size_t n);
void vpsumim(vreal *d, const vreal *restrict a, unsigned *idx, vmask *m, vmask mask, size_t n);

void vmexpand8(vmask *m, uint8_t *mask, size_t n);
void vmexpand16(vmask *m, uint16_t *mask, size_t n);
void vmexpand32(vmask *m, uint32_t *mask, size_t n);
