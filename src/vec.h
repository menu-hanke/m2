#pragma once

#include <stdint.h>
#include <assert.h>

#include "sim.h"

#define VEC_ALIGN M2_VECTOR_SIZE

struct vec_info {
	unsigned n_bands;
	unsigned stride[];
};

struct vec {
	const struct vec_info *info;
	unsigned n_alloc;
	unsigned n_used;
	void *bands[];
};

union vec_tpl {
	uint64_t u64; // repeat bit pattern
	void *p;      // copy from here
};

struct vec_slice {
	struct vec *vec;
	unsigned from;
	unsigned to;
};

#define VEC_HEADER_SIZE(info) (sizeof(struct vec) + (info)->n_bands * sizeof(void *))

void vec_clear(struct vec *v);
void vec_init_range(struct vec *v, unsigned from, unsigned to, union vec_tpl *tpl);
unsigned vec_copy_skip(struct vec *v, void **dst, unsigned n, unsigned *skip);
unsigned vec_copy_skip_s(struct vec *v, void **dst, unsigned n, unsigned *skip);

struct vec_info *simS_vec_create_info(sim *sim, unsigned n_bands, unsigned *strides);
struct vec *simL_vec_create(sim *sim, struct vec_info *info, int lifetime);
void *simF_vec_create_band(sim *sim, struct vec *v, unsigned band);
void *simF_vec_create_band_stride(sim *sim, struct vec *v, unsigned stride);
unsigned simF_vec_alloc(sim *sim, struct vec *v, unsigned n);
void simF_vec_delete(sim *sim, struct vec *v, unsigned n, unsigned *idx);
