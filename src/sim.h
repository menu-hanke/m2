#pragma once

#include "lex.h"
#include "grid.h"
#include "bitmap.h"

#include <stddef.h>
#include <stdint.h>

typedef struct sim sim;
typedef uint64_t sim_branchid;

#define SIM_NO_BRANCH 0

typedef struct sim_env {
	type type;
	size_t zoom_order;
	gridpos zoom_mask;
	struct grid grid;
} sim_env;

typedef struct sim_objvec {
	//uint8_t saved_bands[BITSET_SIZE(SIM_MAX_VAR)] __attribute__((aligned(BITMAP_ALIGN)));
	unsigned n_alloc;
	unsigned n_used;
	unsigned n_bands;
	struct tvec bands[];
} sim_objvec;

// *Temporary* reference to a sim object. Don't hold on to these.
// The ref stays valid (inside branch) until a call to sim_deletev() moves or deletes it.
typedef struct sim_objref {
	sim_objvec *vec;
	size_t idx;
} sim_objref;

sim *sim_create(struct lex *lex);
void sim_destroy(sim *sim);

sim_env *sim_get_env(sim *sim, lexid envid);
void sim_env_pvec(struct pvec *v, sim_env *e);
void sim_env_swap(sim_env *e, void *data);
size_t sim_env_orderz(sim_env *e);
gridpos sim_env_posz(sim_env *e, gridpos pos);
pvalue sim_env_readpos(sim_env *e, gridpos pos);

struct grid *sim_get_objgrid(sim *sim, lexid objid);
void sim_obj_pvec(struct pvec *v, sim_objvec *vec, lexid varid);
void sim_obj_swap(sim_objvec *vec, lexid varid, void *data);
pvalue sim_obj_read1(sim_objref *ref, lexid varid);
void sim_obj_write1(sim_objref *ref, lexid varid, pvalue value);

void sim_allocv(sim *sim, sim_objref *refs, lexid objid, size_t n, gridpos *pos);
void sim_allocvs(sim *sim, sim_objref *refs, lexid objid, size_t n, gridpos *pos);
void sim_deletev(size_t n, sim_objref *refs);
void sim_deletevs(size_t n, sim_objref *refs);
void *sim_frame_alloc(sim *sim, size_t sz, size_t align);
void *sim_alloc_band(sim *sim, sim_objvec *vec, lexid varid);
void *sim_alloc_env(sim *sim, sim_env *e);

void sim_savepoint(sim *sim);
void sim_restore(sim *sim);
void sim_enter(sim *sim);
void sim_exit(sim *sim);
sim_branchid sim_branch(sim *sim, size_t n, sim_branchid *branches);
sim_branchid sim_next_branch(sim *sim);
