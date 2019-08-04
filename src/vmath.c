/* Vectorized math operations. This should probably be replaced by an actual math library,
 * currently it just trusts GCC to auto-vectorize the loops */

#include "vmath.h"
#include "def.h"

#define V(t, step)\
	do {\
		size_t vn = ALIGN(sizeof(t)*(n), M2_VECTOR_SIZE) / sizeof(t);\
		for(size_t i=0;i<vn;i++){\
			step;\
		}\
	} while(0)

void vadd_f64(vf64 *a, size_t n, double c){
	V(double, a[i] += c);
}

void vadd2_f64(vf64 *restrict a, const vf64 *restrict b, size_t n){
	V(double, a[i] += b[i]);
}
