#include "vec.h"
#include "sim.h"
#include "def.h"

#include <stdint.h>
#include <stdlib.h>
#include <stdalign.h>
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
static void F_ensure_capacity(sim *sim, struct vec *v, unsigned n);

void vec_clear(struct vec *v){
	v->n_alloc = 0;
	v->n_used = 0;
	for(unsigned i=0;i<v->info->n_bands;i++)
		v->bands[i] = NULL;
}

void vec_clear_bands(struct vec *v, unsigned n, unsigned *idx){
	for(unsigned i=0;i<n;i++)
		v->bands[idx[i]] = NULL;
}

void vec_init_range(struct vec *v, unsigned from, unsigned to, union vec_tpl *tpl){
	assert(to >= from);
	for(unsigned i=0;i<v->info->n_bands;i++){
		if(v->bands[i]){
			unsigned stride = v->info->stride[i];
			rep_tpl(((char *) v->bands[i]) + stride*from, to-from, stride, tpl[i]);
		}
	}
}

unsigned vec_copy_skip(struct vec *v, void **dst, unsigned n, unsigned *skip){
	qsort(skip, n, sizeof(*skip), cmp_idx);
	return vec_copy_skip_s(v, dst, n, skip);
}

unsigned vec_copy_skip_s(struct vec *v, void **dst, unsigned n, unsigned *skip){
	struct cpy_interval cpy[n + 1];
	unsigned ncpy;
	unsigned tail = calc_intervals_s(cpy, &ncpy, n, skip, v->n_used);
	for(unsigned i=0;i<v->info->n_bands;i++){
		if(v->bands[i])
			copy_intervals(cpy, ncpy, dst[i], v->bands[i], v->info->stride[i]);
	}
	return tail;
}

struct vec_info *simS_vec_create_info(sim *sim, unsigned n_bands, unsigned *strides){
	struct vec_info *info = sim_static_alloc(sim, sizeof(*info) + n_bands*sizeof(*info->stride),
			alignof(*info));

	info->n_bands = n_bands;
	memcpy(info->stride, strides, n_bands * sizeof(*info->stride));

	dv("vec_info<%p>: %u bands\n", info, n_bands);
	return info;
}

struct vec *simL_vec_create(sim *sim, struct vec_info *info, int lifetime){
	struct vec *v = sim_alloc(sim, VEC_HEADER_SIZE(info), alignof(*v), lifetime);

	v->info = info;
	vec_clear(v);

	dv("vec<%p>: info<%p> life=%#x\n", v, info, lifetime);
	return v;
}

void *simF_vec_create_band(sim *sim, struct vec *v, unsigned band){
	return simF_vec_create_band_stride(sim, v, v->info->stride[band]);
}

void *simF_vec_create_band_stride(sim *sim, struct vec *v, unsigned stride){
	void *ret = sim_frame_alloc(sim, v->n_alloc * stride, VEC_ALIGN);

#ifdef DEBUG
	// fill it with NaNs to help the user detect if they are doing something stupid.
	// note that we can't just fill it with all ones, we must use NaNs with ones in exponent
	// and zeros in mantissa to not confuse luajit nan tagging.
	// (if the array isn't supposed to contain doubles/floats then this just fills it with
	// some invalid pattern, which is also completely ok.)
	if(stride == 4 || stride == 8){
		uint64_t tpl = stride == 8 ? 0xfff8000000000000 : 0xffc00000ffc00000;
		mrep_small(ret, v->n_alloc, stride, tpl);
	}
#endif

	return ret;
}

unsigned simF_vec_alloc(sim *sim, struct vec *v, unsigned n){
	F_ensure_capacity(sim, v, n);
	unsigned ret = v->n_used;
	v->n_used += n;
	dv("alloc %u entries [%u-%u] on vector %p (%u/%u used)\n",
			n, ret, v->n_used, v, v->n_used, v->n_alloc);
	return ret;
}

void simF_vec_delete(sim *sim, struct vec *v, unsigned n, unsigned *idx){
	if(!n)
		return;

	void *newbands[v->info->n_bands];
	for(unsigned i=0;i<v->info->n_bands;i++)
		newbands[i] = v->bands[i] ? simF_vec_create_band(sim, v, i) : NULL;

	vec_copy_skip(v, newbands, n, idx);

	memcpy(v->bands, newbands, v->info->n_bands * sizeof(*v->bands));
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

static void F_ensure_capacity(sim *sim, struct vec *v, unsigned n){
	if(v->n_used + n <= v->n_alloc)
		return;

	unsigned na = v->n_alloc;
	if(!na)
		na = SIM_INIT_VEC_SIZE;

	while(na < n+v->n_used)
		na <<= 1;

	dv("realloc vector %p grow %u -> %u\n", v, v->n_alloc, na);

	assert(na == ALIGN(na, VEC_ALIGN));
	v->n_alloc = na;

	// frame-alloc new bands, no need to free old ones since they were frame-alloced as well
	// NOTE: this will not work if we some day do interleaved bands!
	for(unsigned i=0;i<v->info->n_bands;i++){
		void *old = v->bands[i];
		if(old){
			v->bands[i] = simF_vec_create_band(sim, v, i);
			memcpy(v->bands[i], old, v->n_used*v->info->stride[i]);
		}
	}
}
