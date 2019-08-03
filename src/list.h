#pragma once

#include <stddef.h>
#include <stdlib.h>
#include <assert.h>

#define VEC(...) struct { size_t nalloc; size_t nuse; __VA_ARGS__ *data; }
#define VECN(v) ((v).nuse)
#define VECS(v) ((v).nalloc)
#define VECE(v, i) (v).data[({ assert((i) < (v).nuse); (i); })]
#define VECP(v, e) ( ((ptrdiff_t)((e) - (v).data))/sizeof(*(v).data) )

#define VEC_INIT(v, n) vec_init((void**)&(v).data, &(v).nalloc, &(v).nuse, (n), sizeof(*(v).data))
#define VEC_ADD(v) ((typeof(v.data)) vec_add((void**)&(v).data, &(v).nalloc, &(v).nuse, sizeof(*(v).data)))
#define VEC_FREE(v) free((v).data)

static inline void vec_init(void **data, size_t *nalloc, size_t *nuse, size_t n, size_t s){
	*data = malloc(n * s);
	*nalloc = n;
	*nuse = 0;
}

static inline void *vec_add(void **data, size_t *nalloc, size_t *nuse, size_t s){
	if(*nuse >= *nalloc){
		*nalloc *= 2;
		*data = realloc(*data, s*(*nalloc));
	}

	return ((char *) *data) + s*(*nuse)++;
}
