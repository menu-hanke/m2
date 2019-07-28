#pragma once

#include "lex.h"

#include <stddef.h>

typedef struct sim sim;
typedef struct sim_vec sim_vec;

enum {
	SIM_ITER_END  = 0,
	SIM_ITER_NEXT = -1
};

enum {
	SIM_OK             = 0,
	SIM_EOOM           = 1,
	SIM_EDEPTH_LIMIT   = 2,
	SIM_EINVALID_FRAME = 3
};

typedef struct sim_objref {
	sim_vec *vec;
	size_t idx;
} sim_objref;

typedef struct sim_slice {
	sim_vec *vec;
	size_t from;
	size_t to;
} sim_slice;

typedef struct sim_iter {
	sim_objref ref;
	int upref;
} sim_iter;

sim *sim_create(struct lex *lex);
void sim_destroy(sim *sim);

void sim_allocv(sim *sim, sim_slice *pos, lexid objid, sim_objref *uprefs, size_t n);
// TODO deallocv
int sim_first(sim *sim, sim_iter *it, lexid objid, sim_objref *upref, int uprefidx);
int sim_next(sim_iter *it);
sim_vec *sim_first_rv(sim *sim, lexid objid);
sim_vec *sim_next_rv(sim_vec *prev);
void sim_used(sim_vec *vec, sim_slice *slice);
void *sim_varp(sim *sim, sim_objref *ref, lexid objid, lexid varid);
void *sim_varp_base(sim_vec *vec, lexid varid);
pvalue sim_read1p(sim *sim, sim_objref *ref, lexid objid, lexid varid);
void sim_write1p(sim *sim, sim_objref *ref, lexid objid, lexid varid, pvalue value);
sim_objref *sim_get_upref(sim_vec *vec, int uprefidx);

int sim_enter(sim *sim);
void sim_rollback(sim *sim);
int sim_exit(sim *sim);
