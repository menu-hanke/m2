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

/* set all elements of d to constant c */
void vsetc(vreal *d, vreal c, size_t n){
	V(n, d[i] = c);
}

/* add constant c to a and store to d */
void vaddc(vreal *d, vreal *a, vreal c, size_t n){
	V(n, d[i] = a[i] + c);
}

/* add vector b to a and store to d */
void vaddv(vreal *d, vreal *a, const vreal *restrict b, size_t n){
	V(n, d[i] = a[i] + b[i]);
}

/* multiply a by constan c and store to d */
void vmulc(vreal *d, vreal *a, vreal c, size_t n){
	V(n, d[i] = a[i] * c);
}

/* multiply a and b element-wise and store to d */
void vmulv(vreal *d, vreal *a, const vreal *restrict b, size_t n){
	V(n, d[i] = a[i] * b[i]);
}

/* compute area given diameter in a and store to d */
void varead(vreal *d, vreal *a, size_t n){
	V(n, d[i] = PI * a[i] * a[i] / 4);
}

/* sort indices of a */
void vsorti(unsigned *idx, vreal *a, size_t n){
	for(size_t i=0;i<n;i++)
		idx[i] = i;

	// TODO: replace qsort here with inlined sort
	qsort_r(idx, n, sizeof(*idx), cmp_idx, a);
}

/* sum elements of a */
vreal vsum(vreal *a, size_t n){
	vreal ret = 0;
	V(n, ret += a[i]);
	return ret;
}

/* sum elements of a selected by mask */
vreal vsumm(vreal *a, vmask *m, vmask mask, size_t n){
	vreal ret = 0;
	V(n, if(m[i] & mask) ret += a[i]);
	return ret;
}

/* prefix sum a sorted by idx to d */
void vpsumi(vreal *d, const vreal *restrict a, unsigned *idx, size_t n){
	vreal sum = 0;
	for(size_t i=0;i<n;i++){
		unsigned k = idx[i];
		sum += a[k];
		d[k] = sum;
	}
}

/* prefix sum a sorted by idx selected by mask to d */
void vpsumim(vreal *d, const vreal *restrict a, unsigned *idx, vmask *m, vmask mask, size_t n){
	vreal sum = 0;
	for(size_t i=0;i<n;i++){
		unsigned k = idx[i];
		if(m[k] & mask)
			sum += a[k];
		d[k] = sum;
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
