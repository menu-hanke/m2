#pragma once

#include "lex.h"
#include "grid.h"
#include "sim.h"

#include <stddef.h>

#define W_TPL_IDX(varid) ((varid) - BUILTIN_VARS_END)

typedef struct world world;

typedef struct w_vband {
	unsigned stride_bits : 16;
	unsigned type        : 16;
	unsigned last_modify : 32;
	void *data;
} w_vband;

typedef struct w_objvec {
	unsigned n_alloc;
	unsigned n_used;
	unsigned n_bands;
	w_vband bands[];
} w_objvec;

typedef struct w_obj {
	size_t vsize;
	w_objvec *vtemplate;
	struct grid grid;
} w_obj;

// XXX: the 'type' field is unsigned instead of type because luajit doesn't like enum bitfields
typedef struct w_env {
	unsigned type       : 32;
	unsigned zoom_order : 32;
	gridpos zoom_mask;
	struct grid grid;
} w_env;

// *Temporary* reference to a sim object. Don't hold on to these.
// The ref stays valid (inside branch) until a call to sim_deletev() moves or deletes it.
typedef struct w_objref {
	w_objvec *vec;
	size_t idx;
} w_objref;

typedef struct w_objtpl {
	w_obj *obj;
	tvalue defaults[];
} w_objtpl;

world *w_create(sim *sim, struct lex *lex);
void w_destroy(world *w);

w_env *w_get_env(world *w, lexid envid);
void w_env_pvec(struct pvec *v, w_env *e);
void w_env_swap(world *w, w_env *e, void *data);
size_t w_env_orderz(w_env *e);
gridpos w_env_posz(w_env *e, gridpos pos);
tvalue w_env_readpos(w_env *e, gridpos pos);

w_obj *w_get_obj(world *w, lexid objid);
void w_obj_pvec(struct pvec *v, w_objvec *vec, lexid varid);
void w_obj_swap(world *w, w_objvec *vec, lexid varid, void *data);
void *w_vb_varp(w_vband *band, size_t idx);
void w_vb_vcopy(w_vband *band, size_t idx, tvalue v);
void *w_stride_varp(void *data, unsigned stride_bits, size_t idx);
tvalue w_obj_read1(w_objref *ref, lexid varid);
void w_obj_write1(w_objref *ref, lexid varid, tvalue value);

size_t w_tpl_size(w_obj *obj);
void w_tpl_create(w_obj *obj, w_objtpl *tpl);

void w_allocv(world *w, w_objref *refs, w_objtpl *tpl, size_t n, gridpos *pos);
void w_allocvs(world *w, w_objref *refs, w_objtpl *tpl, size_t n, gridpos *pos);
void w_deletev(world *w, size_t n, w_objref *refs);
void w_deletevs(world *w, size_t n, w_objref *refs);
void *w_alloc_band(world *w, w_objvec *vec, lexid varid);
void *w_alloc_env(world *w, w_env *e);
