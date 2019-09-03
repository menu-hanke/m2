#include "vec.h"

#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <assert.h>

struct cpy_interval {
	unsigned dst;
	unsigned src;
	unsigned num;
};

static void rep_tpl(void *dst, unsigned n, unsigned size, union vec_tpl tpl);
static void mrep_memcpy(void *restrict dst, unsigned n, unsigned size, void *restrict src);
static void mrep_small(void *dst, unsigned n, unsigned size, uint64_t tpl);
static unsigned calc_intervals_s(struct cpy_interval *cpy, unsigned *ncpy, unsigned n,
		unsigned *skip, unsigned tail);
static void copy_intervals(struct cpy_interval *cpy, unsigned ncpy, void *restrict dst,
		void *restrict src, unsigned size);
static int cmp_idx(const void *a, const void *b);

void vec_init(struct vec *v, unsigned n_bands){
	memset(v, 0, vec_header_size(n_bands));
	v->n_bands = n_bands;
}

void vec_init_range(struct vec *v, unsigned from, unsigned to, union vec_tpl *tpl){
	assert(to >= from);
	for(unsigned i=0;i<v->n_bands;i++)
		rep_tpl(V_DATA(&v->bands[i], from), to-from, v->bands[i].stride, tpl[i]);
}

unsigned vec_copy_skip(struct vec *v, void **dst, unsigned n, unsigned *skip){
	qsort(skip, n, sizeof(*skip), cmp_idx);
	return vec_copy_skip_s(v, dst, n, skip);
}

unsigned vec_copy_skip_s(struct vec *v, void **dst, unsigned n, unsigned *skip){
	struct cpy_interval cpy[n + 1];
	unsigned ncpy;
	unsigned tail = calc_intervals_s(cpy, &ncpy, n, skip, v->n_used);
	for(unsigned i=0;i<v->n_bands;i++)
		copy_intervals(cpy, ncpy, dst[i], v->bands[i].data, v->bands[i].stride);
	return tail;
}

unsigned vec_header_size(unsigned n_bands){
	return sizeof(struct vec) + n_bands*sizeof(struct vec_band);
}

static void rep_tpl(void *dst, unsigned n, unsigned size, union vec_tpl tpl){
	// Note: this function assumes the vector has no jumps in the sense that
	// stride = element size

	if(size <= 8)
		mrep_small(dst, n, size, tpl.u64);
	else
		mrep_memcpy(dst, n, size, tpl.p);
}

static void mrep_memcpy(void *restrict dst, unsigned n, unsigned size, void *restrict src){
	char *c = dst;

	for(unsigned i=0;i<n;i++,c+=size)
		memcpy(c, src, size);
}

static void mrep_small(void *dst, unsigned n, unsigned size, uint64_t tpl){
	// Speed hack for small copies (it would make me sad to call thousands of 1-byte memsets).
	// This function makes the following assumptions
	//     * size is 1, 2, 4 or 8
	//     * dst is aligned according to size
	//     * we have empty space up to the next alignment of 8 we can write over
	//     * tpl contains the bit pattern to write repeated according to size
	//       (e.g. if size is 2 then the bytes of tpl are ABABABAB, where AB is the pattern
	//       we want to write)
	
	uintptr_t data = (uintptr_t) dst;
	uintptr_t end = data + n*size;

	assert(size == 1 || size == 2 || size == 4 || size == 8);
	assert(!(data % size));

	// align data to 8, this loop works because data is aligned to 1,2,4 or 8 and
	// the value in val is repeated accordingly, so we don't copy anything stupid here
	// another way to this is in 3 steps: first align to 2, then 4 and finally 8,
	// this is probably faster because most allocations will be aligned to 8 bytes anyway
	uint64_t t = tpl;
	while(data%8){
		*((uint8_t *) data) = t & 0xff;
		t >>= 8;
		data++;
	}

	// now we can spray our value all we want
	for(;data<end;data+=8)
		*((uint64_t *) data) = tpl;
}

static unsigned calc_intervals_s(struct cpy_interval *cpy, unsigned *ncpy, unsigned n,
		unsigned *skip, unsigned tail){

	unsigned next = 0, cpos = 0, nc = 0;

	for(size_t i=0;i<n;i++){
		size_t d = skip[i];

		if(d > next){
			cpy[nc].dst = cpos;
			cpy[nc].src = next;
			cpy[nc].num = d - next;
			cpos += cpy[nc].num;
			nc++;
		}

		next = d+1;
	}

	if(next < tail){
		cpy[nc].dst = cpos;
		cpy[nc].src = next;
		cpy[nc].num = tail - next;
		cpos += cpy[nc].num;
		nc++;
	}

	assert(cpos <= tail);
	assert(nc <= n+1);
	assert(tail-cpos <= n); // <= isntead of = because the list can contain duplicates

	*ncpy = nc;
	return cpos;
}

static void copy_intervals(struct cpy_interval *cpy, unsigned ncpy, void *restrict dst,
		void *restrict src, unsigned size){

	char *cd = dst;
	char *cs = src;

	for(unsigned i=0;i<ncpy;i++){
		struct cpy_interval *c = &cpy[i];
		memcpy(cd+c->dst*size, cs+c->src*size, c->num*size);
	}
}

static int cmp_idx(const void *a, const void *b){
	return *((int *) a) - *((int *) b);
}
