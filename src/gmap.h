#pragma once

#include "fhk.h"
#include "bitmap.h"
#include "type.h"
#include "grid.h"
#include "vec.h"
#include "model/model.h"

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

typedef int (*gmap_resolve)(void *, pvalue *);

#define GV_HEADER(...)          \
	const gmap_support *supp;   \
	gmap_resolve resolve;       \
	tvalue udata;               \
	const char *name;           \
	union {                     \
		struct {                \
			unsigned type : 8;  \
			__VA_ARGS__         \
		};                      \
		uint64_t u64;           \
	} flags

// the reason this is done weirdly is because otherwise gcc will emit movzx for each separate
// 16 bit field and we want to get them all in 1 mov.
// this is micro-optimized since the gmap_res_* functions can take 10-20% of solver time
// with fast models and low amount of shared parameters.
#define GV_GETFLAGS(name,v) typeof((v)->flags) name = {.u64=(v)->flags.u64}

struct gmap_any {
	GV_HEADER();
};

// maps vector component values to fhk variables:
//
//  band + *offset_bind ->--v                     **idx_bind
//  bind->bands: . . . [ ] [*] [ ] . . .               |
//                          |                          v
//                          band->data ----> [][][][][][  + ][][][][][][][]
//                                                        ^- offset
struct gv_vcomponent {
	GV_HEADER(
			unsigned offset : 16;
			unsigned stride : 16;
			unsigned band   : 16;
	);
	unsigned *offset_bind;
	unsigned **idx_bind;
	struct vec **v_bind;
};

// maps grid elements to fhk variables:
//    |   |   |
// ---|---|---|---
//    |   | *<|------ grid_zoom_up(*bind, POSITION_ORDER, grid->order)
// ---|---|---|---    + target_offset
//    |   |   |   
// ---|---|---|---
struct gv_grid {
	GV_HEADER(
			unsigned offset : 16;
	);
	struct grid *grid;
	gridpos *bind;
};

// map data at pointer to fhk variables:
// *((tvalue *) ref)
struct gv_data {
	GV_HEADER();
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

int gmap_res_vec(void *v, pvalue *p);
int gmap_res_grid(void *v, pvalue *p);
int gmap_res_data(void *v, pvalue *p);

void gmap_mark_visible(struct fhk_graph *G, bm8 *vmask, unsigned reason, tvalue parm);
void gmap_mark_nonconstant(struct fhk_graph *G, bm8 *vmask, unsigned reason, tvalue parm);
