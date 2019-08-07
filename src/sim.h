#pragma once

#include "lex.h"
#include "grid.h"
#include "bitmap.h"

#include <stddef.h>
#include <stdint.h>

typedef struct sim sim;
typedef uint64_t sim_branchid;

#define SIM_NO_BRANCH 0
#define SIM_TPL_IDX(varid) ((varid) - BUILTIN_VARS_END)

typedef struct sim_vband {
	unsigned stride_bits : 16;
	unsigned type        : 16;
	unsigned last_modify : 32;
	void *data;
} sim_vband;

typedef struct sim_objvec {
	unsigned n_alloc;
	unsigned n_used;
	unsigned n_bands;
	sim_vband bands[];
} sim_objvec;

typedef struct sim_obj {
	size_t vsize;
	sim_objvec *vtemplate;
	struct grid grid;
} sim_obj;

// XXX: the 'type' field is unsigned instead of type because luajit doesn't like enum bitfields
typedef struct sim_env {
	unsigned type       : 32;
	unsigned zoom_order : 32;
	gridpos zoom_mask;
	struct grid grid;
} sim_env;

// *Temporary* reference to a sim object. Don't hold on to these.
// The ref stays valid (inside branch) until a call to sim_deletev() moves or deletes it.
typedef struct sim_objref {
	sim_objvec *vec;
	size_t idx;
} sim_objref;

typedef struct sim_objtpl {
	sim_obj *obj;
	tvalue defaults[];
} sim_objtpl;

sim *sim_create(struct lex *lex);
void sim_destroy(sim *sim);

sim_env *sim_get_env(sim *sim, lexid envid);
void sim_env_pvec(struct pvec *v, sim_env *e);
void sim_env_swap(sim *sim, sim_env *e, void *data);
size_t sim_env_orderz(sim_env *e);
gridpos sim_env_posz(sim_env *e, gridpos pos);
tvalue sim_env_readpos(sim_env *e, gridpos pos);

sim_obj *sim_get_obj(sim *sim, lexid objid);
void sim_obj_pvec(struct pvec *v, sim_objvec *vec, lexid varid);
void sim_obj_swap(sim *sim, sim_objvec *vec, lexid varid, void *data);
void *sim_vb_varp(sim_vband *band, size_t idx);
void sim_vb_vcopy(sim_vband *band, size_t idx, tvalue v);
void *sim_stride_varp(void *data, unsigned stride_bits, size_t idx);
tvalue sim_obj_read1(sim_objref *ref, lexid varid);
void sim_obj_write1(sim_objref *ref, lexid varid, tvalue value);

size_t sim_tpl_size(sim_obj *obj);
void sim_tpl_create(sim_obj *obj, sim_objtpl *tpl);

void sim_allocv(sim *sim, sim_objref *refs, sim_objtpl *tpl, size_t n, gridpos *pos);
void sim_allocvs(sim *sim, sim_objref *refs, sim_objtpl *tpl, size_t n, gridpos *pos);
void sim_deletev(sim *sim, size_t n, sim_objref *refs);
void sim_deletevs(sim *sim, size_t n, sim_objref *refs);
void *sim_frame_alloc(sim *sim, size_t sz, size_t align);
void *sim_alloc_band(sim *sim, sim_objvec *vec, lexid varid);
void *sim_alloc_env(sim *sim, sim_env *e);

void sim_savepoint(sim *sim);
void sim_restore(sim *sim);
void sim_enter(sim *sim);
void sim_exit(sim *sim);
sim_branchid sim_branch(sim *sim, size_t n, sim_branchid *branches);
sim_branchid sim_next_branch(sim *sim);
