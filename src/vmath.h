#pragma once

#include "def.h"

#include <stddef.h>
#include <stdint.h>

typedef M2_VECTOR_REAL vreal;
typedef M2_VECTOR_MASK vmask;

void vsetc(vreal *d, vreal c, size_t n);
void vsaddc(vreal *d, vreal a, vreal *x, vreal b, size_t n);
void vaddc(vreal *d, vreal *x, vreal c, size_t n);
void vaddsv(vreal *d, vreal *x, vreal a, const vreal *restrict y, size_t n);
void vaddv(vreal *d, vreal *x, const vreal *restrict y, size_t n);
void vscale(vreal *d, vreal *x, vreal a, size_t n);
void vmulv(vreal *d, vreal *x, const vreal *restrict y, size_t n);
void vrefl(vreal *d, vreal a, vreal *x, const vreal *restrict y, size_t n);
void varead(vreal *d, vreal *x, size_t n);
void vsorti(unsigned *idx, vreal *x, size_t n);
vreal vsum(vreal *x, size_t n);
vreal vsumm(vreal *x, vmask *m, vmask mask, size_t n);
void vpsumi(vreal *d, const vreal *restrict x, unsigned *idx, size_t n);
void vpsumim(vreal *d, const vreal *restrict x, unsigned *idx, vmask *m, vmask mask, size_t n);

void vmexpand8(vmask *m, uint8_t *mask, size_t n);
void vmexpand16(vmask *m, uint16_t *mask, size_t n);
void vmexpand32(vmask *m, uint32_t *mask, size_t n);
