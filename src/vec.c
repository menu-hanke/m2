#include "vec.h"
#include "sim.h"
#include "mem.h"
#include "def.h"

#include <stdint.h>
#include <stdlib.h>
#include <stdalign.h>
#include <string.h>
#include <assert.h>

struct cpy_interval {
	uint32_t dst;
	uint32_t src;
	uint32_t num;
};

static uint32_t calc_intervals_s(struct cpy_interval *cpy, uint32_t *ncpy, uint32_t n,
		uint32_t *skip, uint32_t tail);
static void copy_intervals(struct cpy_interval *cpy, uint32_t ncpy, void *restrict dst,
		void *restrict src, uint32_t size);
static int cmp_idx(const void *a, const void *b);
static void F_ensure_capacity(sim *sim, struct vec *v, uint32_t n);

void vec_clear(struct vec *v){
	v->n_alloc = 0;
	v->n_used = 0;
	for(size_t i=0;i<v->info->n_bands;i++)
		v->bands[i] = NULL;
}

void vec_clear_bands(struct vec *v, uint16_t n, uint16_t *idx){
	for(size_t i=0;i<n;i++)
		v->bands[idx[i]] = NULL;
}

uint32_t vec_copy_skip(struct vec *v, void **dst, uint32_t n, uint32_t *skip){
	qsort(skip, n, sizeof(*skip), cmp_idx); // XXX
	return vec_copy_skip_s(v, dst, n, skip);
}

uint32_t vec_copy_skip_s(struct vec *v, void **dst, uint32_t n, uint32_t *skip){
	struct cpy_interval cpy[n + 1];
	uint32_t ncpy;
	uint32_t tail = calc_intervals_s(cpy, &ncpy, n, skip, v->n_used);
	for(uint32_t i=0;i<v->info->n_bands;i++){
		if(v->bands[i])
			copy_intervals(cpy, ncpy, dst[i], v->bands[i], v->info->stride[i]);
	}
	return tail;
}

struct vec_info *simS_vec_create_info(sim *sim, uint16_t n_bands, uint16_t *strides){
	struct vec_info *info = sim_alloc(sim, sizeof(*info) + n_bands*sizeof(*info->stride),
			alignof(*info), SIM_STATIC);

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

void *simF_vec_create_band(sim *sim, struct vec *v, uint16_t band){
	return simF_vec_create_band_stride(sim, v, v->info->stride[band]);
}

void *simF_vec_create_band_stride(sim *sim, struct vec *v, uint16_t stride){
	return sim_alloc(sim, v->n_alloc * stride, VEC_ALIGN, SIM_FRAME);
}

uint32_t simF_vec_alloc(sim *sim, struct vec *v, uint32_t n){
	F_ensure_capacity(sim, v, n);
	uint32_t ret = v->n_used;
	v->n_used += n;
	dv("alloc %u entries [%u-%u] on vector %p (%u/%u used)\n",
			n, ret, v->n_used, v, v->n_used, v->n_alloc);
	return ret;
}

void simF_vec_delete(sim *sim, struct vec *v, uint32_t n, uint32_t *idx){
	if(!n)
		return;

	void *newbands[v->info->n_bands];
	for(size_t i=0;i<v->info->n_bands;i++)
		newbands[i] = v->bands[i] ? simF_vec_create_band(sim, v, i) : NULL;

	vec_copy_skip(v, newbands, n, idx);

	memcpy(v->bands, newbands, v->info->n_bands * sizeof(*v->bands));
}

static uint32_t calc_intervals_s(struct cpy_interval *cpy, uint32_t *ncpy, uint32_t n,
		uint32_t *skip, uint32_t tail){

	uint32_t next = 0, cpos = 0, nc = 0;

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

static void copy_intervals(struct cpy_interval *cpy, uint32_t ncpy, void *restrict dst,
		void *restrict src, uint32_t size){

	char *cd = dst;
	char *cs = src;

	for(size_t i=0;i<ncpy;i++){
		struct cpy_interval *c = &cpy[i];
		memcpy(cd+c->dst*size, cs+c->src*size, c->num*size);
	}
}

static int cmp_idx(const void *a, const void *b){
	return *((int *) a) - *((int *) b);
}

static void F_ensure_capacity(sim *sim, struct vec *v, uint32_t n){
	if(v->n_used + n <= v->n_alloc)
		return;

	uint32_t na = v->n_alloc;
	if(!na)
		na = 32;

	while(na < n+v->n_used)
		na <<= 1;

	dv("realloc vector %p grow %u -> %u\n", v, v->n_alloc, na);

	assert(na == ALIGN(na, VEC_ALIGN));
	v->n_alloc = na;

	// frame-alloc new bands, no need to free old ones since they were frame-alloced as well
	// NOTE: this will not work if we some day do interleaved bands!
	for(size_t i=0;i<v->info->n_bands;i++){
		void *old = v->bands[i];
		if(old){
			v->bands[i] = simF_vec_create_band(sim, v, i);
			memcpy(v->bands[i], old, v->n_used*v->info->stride[i]);
		}
	}
}
