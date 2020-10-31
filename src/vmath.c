/* Vectorized math operations. This should probably be replaced by an actual math library,
 * currently it just trusts GCC to auto-vectorize the loops */

#include "vmath.h"

#include <stddef.h>
#include <stdlib.h>
#include <math.h>

#define V(n, step)\
	do {\
		_Pragma("omp simd")\
		for(size_t i=0;i<n;i++){ step; }\
	} while(0)

#define Vnosimd(n, step)\
	do {\
		for(size_t i=0;i<n;i++){ step; }\
	} while(0)

/* set constant
 * d <- c */
void vdsetc(double *d, double c, size_t n){
	V(n, d[i] = c);
}

/* scale and add constant
 * d <- ax + b */
void vdsaddc(double *d, double a, double *x, double b, size_t n){
	V(n, d[i] = a*x[i] + b);
}

/* add constant
 * d <- x + c */
void vdaddc(double *d, double *x, double c, size_t n){
	vdsaddc(d, 1, x, c, n);
}

/* add scaled vector
 * d <- x + ay */
void vdaddsv(double *d, double *x, double a, const double *restrict y, size_t n){
	V(n, d[i] = x[i] + a*y[i]);
}

/* add vector
 * d <- x + y */
void vdaddv(double *d, double *x, const double *restrict y, size_t n){
	vdaddsv(d, x, 1, y, n);
}

/* scale vector
 * d <- ax */
void vdscale(double *d, double *x, double a, size_t n){
	V(n, d[i] = a*x[i]);
}

/* multiply element-wise
 * d <- x * y */
void vdmulv(double *d, double *x, const double *restrict y, size_t n){
	V(n, d[i] = x[i] * y[i]);
}

/* generalized reflection of x around y
 * d <- y + a*(y - x) */
void vdrefl(double *d, double a, double *x, const double *restrict y, size_t n){
	V(n, d[i] = y[i] + a*(y[i] - x[i]));
}

/* area from diameter
 * d <- (pi/4)*x^2 */
void vdaread(double *d, double *x, size_t n){
	V(n, d[i] = (M_PI/4) * x[i] * x[i]);
}

/* sum elements
 * sum(x[i] : i=1..n) */
double vdsum(double *x, size_t n){
	double ret = 0;
	V(n, ret += x[i]);
	return ret;
}

/* sum elements selected by mask
 * sum(x[i] : (1<<k[i])&mask, i=1..n)*/
double vdsumm8(double *x, uint8_t *k, uint64_t mask, size_t n){
	double ret = 0;
	V(n, if((1ULL << k[i]) & mask) ret += x[i]);
	return ret;
}

/* dot product
 * sum(x*y) */
double vddot(double *x, double *y, size_t n){
	double ret = 0;
	V(n, ret += x[i]*y[i]);
	return ret;
}

/* weighted average
 * sum(x*w) / sum(w) */
double vdavgw(const double *restrict x, const double *restrict w, size_t n){
	double sxw = 0, sw = 0;
	V(n, sxw += x[i]*w[i]; sw += w[i]);
	return sxw / sw;
}
