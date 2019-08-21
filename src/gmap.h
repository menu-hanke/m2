#pragma once

/* Mapping of world "objects" to fhk graph.
 * Note that a world object does not necessarily correspond to 1 variable in the graph.
 * An fhk variable may represented by:
 *   - object vector band   (var)
 *   - env var              (env)
 *   - global var           (global)
 *   - function pointer     (virtual)
 *   - nothing              (computed)
 *
 * Technically each type is a special case of virtual, but they are implemented separately for
 * efficiency. 
 */

#include "fhk.h"
#include "bitmap.h"
#include "world.h"
#include "lex.h"
#include "exec.h"

#include <stdint.h>

enum {
	GMAP_VAR = 0,
	GMAP_ENV,
	GMAP_GLOBAL,
	GMAP_VIRTUAL,
	GMAP_COMPUTED
};

enum {
	GMAP_NEW_OBJECT = 0,
	GMAP_NEW_Z
};

typedef struct gmap_change {
	// Note: here uint*_t types must be used, bit fields in unions don't work
	// correctly in luajit
	uint8_t type;
	union {
		uint8_t order;
		uint32_t objid;
	};
} gmap_change;

typedef struct gmap_type {
	unsigned support_type : 8;
	unsigned resolve_type : 8;
} gmap_type;

#define GV_HEADER\
	gmap_type type;\
	const char *name

struct gmap_any {
	GV_HEADER;
};

struct gv_var {
	GV_HEADER;
	unsigned objid;
	lexid varid;
	w_objref *wbind;
};

struct gv_env {
	GV_HEADER;
	w_env *wenv;
	gridpos *zbind;
};

struct gv_global {
	GV_HEADER;
	w_global *wglob;
};

struct gv_computed {
	GV_HEADER;
};

struct gv_virtual {
	union {
		struct { GV_HEADER; };
		struct gv_var var;
		struct gv_env env;
	};

	// Note: if needed, you can add is_reachable/is_supported callbacks here and
	// call them when support_type=GMAP_VIRTUAL, however that will probably never be useful
	pvalue (*resolve)(void *udata);
	void *udata;
};

struct gmap_model {
	const char *name;
	ex_func *f;
};

void gmap_hook(struct fhk_graph *G);
void gmap_bind(struct fhk_graph *G, unsigned idx, struct gmap_any *g);
void gmap_unbind(struct fhk_graph *G, unsigned idx);
void gmap_bind_model(struct fhk_graph *G, unsigned idx, struct gmap_model *m);
void gmap_unbind_model(struct fhk_graph *G, unsigned idx);

void gmap_mark_reachable(struct fhk_graph *G, bm8 *vmask, gmap_change change);
void gmap_mark_supported(struct fhk_graph *G, bm8 *vmask, gmap_change change);

void gmap_make_reset_masks(struct fhk_graph *G, bm8 *vmask, bm8 *mmask);

void gmap_init(struct fhk_graph *G, bm8 *init_v);
void gmap_reset(struct fhk_graph *G, bm8 *reset_v, bm8 *reset_m);

struct gs_vec_args {
	struct fhk_graph *G;
	w_obj *wobj;
	w_objref *wbind;
	gridpos *zbind;
	bm8 *reset_v;
	bm8 *reset_m;
	size_t nv;
	struct fhk_var **xs;
	type *types;
};

void gmap_solve_vec(w_objvec *vec, void **res, struct gs_vec_args *arg);
