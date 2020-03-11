#include "graph.h"
#include "type.h"
#include "mappings.h"

#include <stdint.h>
#include <stdbool.h>

static bool iter_range_begin(struct fhkM_iter_range *iv);
static bool iter_range_next(struct fhkM_iter_range *iv);

void fhkM_range_init(struct fhkM_iter_range *iv){
	iv->iter.begin = (bool (*)(void *)) iter_range_begin;
	iv->iter.next = (bool (*)(void *)) iter_range_next;
}

tvalue *fhkM_data_read(struct fhkM_dataV *v){
	return v->ref;
}

tvalue *fhkM_vec_read(struct fhkM_vecV *v, uint64_t flg){
	FHKG_FLAGS(v) flags = {.u64 = flg};
	struct vec *vec = *v->vec;
	unsigned idx = *v->idx;
	void *band = vec->bands[flags.band];
	return (tvalue *) (((char *) band) + (flags.stride * idx + flags.offset));
}

static bool iter_range_begin(struct fhkM_iter_range *iv){
	iv->idx = 0;
	return iv->len > 0;
}

static bool iter_range_next(struct fhkM_iter_range *iv){
	return ++iv->idx < iv->len;
}
