#pragma once

#include "lex.h"
#include "grid.h"
#include "sim.h"

#include <stddef.h>

typedef struct world world;

// XXX: the 'type' field is unsigned instead of type because luajit doesn't like enum bitfields
typedef struct w_env {
	unsigned type       : 32;
	unsigned zoom_order : 32;
	gridpos zoom_mask;
	struct grid grid;
} w_env;

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
	int z_band;
	size_t vsize;
	w_objvec vtemplate;
} w_obj;

#define W_ISSPATIAL(obj) ((obj)->z_band >= 0)

typedef struct w_objgrid {
	w_obj *obj;
	struct grid grid;
} w_objgrid;

// *Temporary* reference to a sim object. Don't hold on to these.
// The ref stays valid (inside branch) until a call to sim_deletev() moves or deletes it.
typedef struct w_objref {
	w_objvec *vec;
	size_t idx;
} w_objref;

typedef struct w_objtpl {
	tvalue defaults[0];
} w_objtpl;

world *w_create(sim *sim);
void w_destroy(world *w);

w_env *w_define_env(world *w, type type, size_t resolution);
w_obj *w_define_obj(world *w, size_t nv, type *vtypes);
w_objgrid *w_define_objgrid(world *w, w_obj *obj, size_t order);

void w_env_swap(world *w, w_env *e, void *data);
size_t w_env_orderz(w_env *e);
gridpos w_env_posz(w_env *e, gridpos pos);
tvalue w_env_readpos(w_env *e, gridpos pos);

void w_obj_swap(world *w, w_objvec *vec, lexid varid, void *data);
void *w_vb_varp(w_vband *band, size_t idx);
void w_vb_vcopy(w_vband *band, size_t idx, tvalue v);
void *w_stride_varp(void *data, unsigned stride_bits, size_t idx);
tvalue w_obj_read1(w_objref *ref, lexid varid);
void w_obj_write1(w_objref *ref, lexid varid, tvalue value);

size_t w_tpl_size(w_obj *obj);
void w_tpl_create(w_obj *obj, w_objtpl *tpl);

void *w_env_create_data(world *w, w_env *e);
w_objvec *w_obj_create_vec(world *w, w_obj *obj);

size_t w_objvec_alloc(world *w, w_objvec *vec, w_objtpl *tpl, size_t n);
size_t w_objvec_delete(world *w, w_objvec *vec, size_t n, size_t *del);
size_t w_objvec_delete_s(world *w, w_objvec *vec, size_t n, size_t *del);
void *w_objvec_create_band(world *w, w_objvec *vec, lexid varid);
void w_objgrid_alloc(world *w, w_objref *refs, w_objgrid *g, w_objtpl *tpl, size_t n,
		gridpos *pos);
void w_objgrid_alloc_s(world *w, w_objref *refs, w_objgrid *g, w_objtpl *tpl, size_t n,
		gridpos *pos);
void w_objref_delete(world *w, size_t n, w_objref *refs);
void w_objref_delete_s(world *w, size_t n, w_objref *refs);
gridpos w_objgrid_posz(w_objgrid *g, gridpos pos);
w_objvec *w_objgrid_write(world *w, w_objgrid *g, gridpos z);
