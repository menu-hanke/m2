/* Vectorized math operations. This should probably be replaced by an actual math library,
 * currently it just trusts GCC to auto-vectorize the loops */

#include "vmath.h"
#include "def.h"

#define V(t, step)\
	do {\
		size_t vn = ALIGN(sizeof(t)*(n), M2_VECTOR_SIZE) / sizeof(t);\
		_Pragma("omp simd")\
		for(size_t i=0;i<vn;i++){\
			step;\
		}\
	} while(0)

void vset_f64(vf64 *d, double c, size_t n){
	V(double, d[i] = c);
}

void vadd_f64s(vf64 *d, vf64 *a, double c, size_t n){
	V(double, d[i] = a[i] + c);
}

void vadd_f64v(vf64 *d, vf64 *a, const vf64 *restrict b, size_t n){
	V(double, d[i] = a[i] + b[i]);
}
