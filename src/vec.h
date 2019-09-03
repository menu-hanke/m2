#pragma once

#include <stdint.h>
#include <assert.h>

struct vec_band {
	unsigned stride;
	unsigned tag;
	void *data;
};

struct vec {
	unsigned n_alloc;
	unsigned n_used;
	unsigned n_bands;
	struct vec_band bands[];
};

union vec_tpl {
	void *p;
	uint64_t u64;
};

struct vec_ref {
	struct vec *vec;
	unsigned idx;
};

struct vec_slice {
	struct vec *vec;
	unsigned from;
	unsigned to;
};

#define V_DATA(v, i) ((void *) ((char *)(v)->data) + (i)*(v)->stride)
#define V_BAND(v, i) (&(v)->bands[({ assert(((unsigned)(i)) < (v)->n_bands); (i); })])
void vec_init(struct vec *v, unsigned n_bands);
void vec_init_range(struct vec *v, unsigned from, unsigned to, union vec_tpl *tpl);
unsigned vec_copy_skip(struct vec *v, void **dst, unsigned n, unsigned *skip);
unsigned vec_copy_skip_s(struct vec *v, void **dst, unsigned n, unsigned *skip);
unsigned vec_header_size(unsigned n_bands);
