#pragma once

#include "fhk.h"
#include "bitmap.h"
#include "type.h"
#include "model.h"
#include "grid.h"
#include "vec.h"

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

enum {
	GMAP_BIND_OBJECT,
	GMAP_BIND_Z,
	GMAP_BIND_GLOBAL
};

typedef struct gmap_support {
	bool (*is_visible)(tvalue to, unsigned reason, tvalue parm);
	bool (*is_constant)(tvalue to, unsigned reason, tvalue parm);
} gmap_support;

typedef tvalue (*gmap_resolve)(void *);

#define GV_HEADER\
	const gmap_support *supp;    \
	gmap_resolve resolve;        \
	tvalue udata;                \
	const char *name;            \
	unsigned target_type : 16

struct gmap_any {
	GV_HEADER;
};

struct gv_vec {
	GV_HEADER;
	unsigned target_offset : 16;
	unsigned target_band   : 16;
	struct vec_ref *bind;
};

struct gv_grid {
	GV_HEADER;
	unsigned target_offset : 16;
	struct grid *grid;
	gridpos *bind;
};

struct gv_data {
	GV_HEADER;
	void *ref;
};

struct gmap_model {
	const char *name;
	struct model *mod;
};

void gmap_hook(struct fhk_graph *G);
void gmap_bind(struct fhk_graph *G, unsigned idx, struct gmap_any *g);
void gmap_unbind(struct fhk_graph *G, unsigned idx);
void gmap_bind_model(struct fhk_graph *G, unsigned idx, struct gmap_model *m);
void gmap_unbind_model(struct fhk_graph *G, unsigned idx);

void gmap_supp_obj_var(struct gmap_any *v, uint64_t objid);
void gmap_supp_grid_env(struct gmap_any *v, uint64_t order);
void gmap_supp_global(struct gmap_any *v);

tvalue gmap_res_vec(void *v);
tvalue gmap_res_grid(void *v);
tvalue gmap_res_data(void *v);

void gmap_mark_visible(struct fhk_graph *G, bm8 *vmask, unsigned reason, tvalue parm);
void gmap_mark_nonconstant(struct fhk_graph *G, bm8 *vmask, unsigned reason, tvalue parm);

void gmap_make_reset_masks(struct fhk_graph *G, bm8 *vmask, bm8 *mmask);

void gmap_init(struct fhk_graph *G, bm8 *init_v);

struct gmap_solver_vec_bind {
	struct vec_ref *v_bind;
	gridpos *z_bind;
	int z_band;
};

void gmap_solve_vec(struct gmap_solver_vec_bind *bind, struct fhk_solver *solver, struct vec *vec);
