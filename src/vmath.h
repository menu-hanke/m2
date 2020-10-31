#pragma once

/* small math kernel library
 * syntax: v<dtype><operation><mode>
 */

#include <stddef.h>
#include <stdint.h>

void vdsetc(double *d, double c, size_t n);
void vdsaddc(double *d, double a, double *x, double b, size_t n);
void vdaddc(double *d, double *x, double c, size_t n);
void vdaddsv(double *d, double *x, double a, const double *restrict y, size_t n);
void vdaddv(double *d, double *x, const double *restrict y, size_t n);
void vdscale(double *d, double *x, double a, size_t n);
void vdmulv(double *d, double *x, const double *restrict y, size_t n);
void vdrefl(double *d, double a, double *x, const double *restrict y, size_t n);
void vdaread(double *d, double *x, size_t n);
double vdsum(double *x, size_t n);
double vdsumm8(double *x, uint8_t *k, uint64_t mask, size_t n);
double vddot(double *x, double *y, size_t n);
double vdavgw(const double *restrict x, const double *restrict w, size_t n);
