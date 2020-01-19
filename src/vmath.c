/* Vectorized math operations. This should probably be replaced by an actual math library,
 * currently it just trusts GCC to auto-vectorize the loops */

#define _GNU_SOURCE /* for qsort_r - remove when use of qsort is removed */

#include "vmath.h"
#include "def.h"

#include <stddef.h>
#include <stdlib.h>
#include <math.h>

/* cast so it also works with floats, otherwise we get unwanted conversions */
#define PI ((vreal) M_PI)

static int cmp_idx(const void *a, const void *b, void *u);

#define ALIGN_SIZE(n) (ALIGN((n)*sizeof(vreal))/sizeof(vreal))
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
void vsetc(vreal *d, vreal c, size_t n){
	V(n, d[i] = c);
}

/* scale and add constant
 * d <- ax + b */
void vsaddc(vreal *d, vreal a, vreal *x, vreal b, size_t n){
	V(n, d[i] = a*x[i] + b);
}

/* add constant
 * d <- x + c */
void vaddc(vreal *d, vreal *x, vreal c, size_t n){
	vsaddc(d, 1, x, c, n);
}

/* add scaled vector
 * d <- x + ay */
void vaddsv(vreal *d, vreal *x, vreal a, const vreal *restrict y, size_t n){
	V(n, d[i] = x[i] + a*y[i]);
}

/* add vector
 * d <- x + y */
void vaddv(vreal *d, vreal *x, const vreal *restrict y, size_t n){
	vaddsv(d, x, 1, y, n);
}

/* scale vector
 * d <- ax */
void vscale(vreal *d, vreal *x, vreal a, size_t n){
	V(n, d[i] = a*x[i]);
}

/* multiply element-wise
 * d <- x * y */
void vmulv(vreal *d, vreal *x, const vreal *restrict y, size_t n){
	V(n, d[i] = x[i] * y[i]);
}

/* generalized reflection of x around y
 * d <- y + a*(y - x) */
void vrefl(vreal *d, vreal a, vreal *x, const vreal *restrict y, size_t n){
	V(n, d[i] = y[i] + a*(y[i] - x[i]));
}

/* area from diameter
 * d <- (pi/4)*x^2 */
void varead(vreal *d, vreal *x, size_t n){
	V(n, d[i] = (PI/4) * x[i] * x[i]);
}

/* sort indices largest first
 * x[idx[i]] >= x[idx[j]] when i >= j */
void vsorti(unsigned *idx, vreal *x, size_t n){
	for(size_t i=0;i<n;i++)
		idx[i] = i;

	// TODO: replace qsort here with inlined sort
	qsort_r(idx, n, sizeof(*idx), cmp_idx, x);
}

/* sum elements
 * sum(x[i] : i=1..n) */
vreal vsum(vreal *x, size_t n){
	vreal ret = 0;
	V(n, ret += x[i]);
	return ret;
}

/* sum elements selected by mask
 * sum(x[i] : m[i]&mask, i=1..n)*/
vreal vsumm(vreal *x, vmask *m, vmask mask, size_t n){
	vreal ret = 0;
	V(n, if(m[i] & mask) ret += x[i]);
	return ret;
}

/* weighted average
 * sum(x*w) / sum(w) */
vreal vavgw(const vreal *restrict x, const vreal *restrict w, size_t n){
	vreal sxw = 0, sw = 0;
	V(n, sxw += x[i]*w[i]; sw += w[i]);
	return sxw / sw;
}

/* prefix sum by index sorting
 * d[idx[i]] <- sum(x[idx[j]] : j=1..i) */
void vpsumi(vreal *d, const vreal *restrict x, unsigned *idx, size_t n){
	vreal sum = 0;
	for(size_t i=0;i<n;i++){
		unsigned k = idx[i];
		d[k] = sum;
		sum += x[k];
	}
}

/* prefix sum by index sorting selected by mask
 * d[idx[i]] <- sum(x[idx[j]] : m[ixd[j]]&mask, j=1..i) */
void vpsumim(vreal *d, const vreal *restrict x, unsigned *idx, vmask *m, vmask mask, size_t n){
	vreal sum = 0;
	for(size_t i=0;i<n;i++){
		unsigned k = idx[i];
		d[k] = sum;
		if(m[k] & mask)
			sum += x[k];
	}
}

/* expand 8-bit mask */
void vmexpand8(vmask *m, uint8_t *mask, size_t n){
	V(n, m[i] = mask[i]);
}

/* expand 16-bit mask */
void vmexpand16(vmask *m, uint16_t *mask, size_t n){
	V(n, m[i] = mask[i]);
}

/* expand 32-bit mask */
void vmexpand32(vmask *m, uint32_t *mask, size_t n){
	V(n, m[i] = mask[i]);
}

static int cmp_idx(const void *a, const void *b, void *u){
	unsigned ia = *(unsigned *) a;
	unsigned ib = *(unsigned *) b;
	vreal *v = (vreal *) u;
	return (v[ia] < v[ib]) - (v[ia] > v[ib]);
}
