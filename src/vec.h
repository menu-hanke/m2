#pragma once

#include <stdint.h>
#include <assert.h>

#include "sim.h"

struct vec_info {
	uint16_t n_bands;
	uint16_t stride[];
};

// usage:
//
//     struct my_vec {
//         struct vec _v;
//         double *band1;
//         float *band2;
//         ...
//         int *bandN;
//     }
//
struct vec {
	const struct vec_info *info;
	uint32_t n_alloc;
	uint32_t n_used;
	void *bands[];
};

struct vec_slice {
	struct vec *vec;
	uint32_t from;
	uint32_t to;
};

#define VEC_HEADER_SIZE(info) (sizeof(struct vec) + (info)->n_bands * sizeof(void *))

void vec_clear(struct vec *v);
void vec_clear_bands(struct vec *v, uint16_t n, uint16_t *idx);
uint32_t vec_copy_skip(struct vec *v, void **dst, uint32_t n, uint32_t *skip);
uint32_t vec_copy_skip_s(struct vec *v, void **dst, uint32_t n, uint32_t *skip);

struct vec_info *simS_vec_create_info(sim *sim, uint16_t n_bands, uint16_t *strides);
struct vec *simL_vec_create(sim *sim, struct vec_info *info, int lifetime);
void *simF_vec_create_band(sim *sim, struct vec *v, uint16_t band);
void *simF_vec_create_band_stride(sim *sim, struct vec *v, uint16_t stride);
uint32_t simF_vec_alloc(sim *sim, struct vec *v, uint32_t n);
void simF_vec_delete(sim *sim, struct vec *v, uint32_t n, uint32_t *idx);
