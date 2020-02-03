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

enum gmap_rtype {
	GMAP_VEC,
	GMAP_ENV,
	GMAP_DATA,
	GMAP_INTERRUPT,
	GMAP_COMPUTED
};

#define GMAP_VHEADER(...)  \
	union {                \
		uint64_t u64;      \
		struct {           \
			uint8_t rtype; \
			uint8_t vtype; \
			__VA_ARGS__    \
		};                 \
	} flags;               \
	const char *name

struct gv_any {
	GMAP_VHEADER();
};

// maps vector component values to fhk variables:
//
//                  band ---v                      *idx_bind
//  bind->bands: . . . [ ] [*] [ ] . . .               |
//                          |                          v
//                          band->data ----> [][][][][][  + ][][][][][][][]
//                                                        ^- offset
struct gv_vec {
	GMAP_VHEADER(		
			uint16_t offset;
			uint16_t stride;
			uint16_t band;
	);
	unsigned *idx_bind;
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
	GMAP_VHEADER(
			uint16_t offset;
	);
	struct grid *grid;
	gridpos *bind;
};

// map data at pointer to fhk variables:
// *((tvalue *) ref)
struct gv_data {
	GMAP_VHEADER();
	void *ref;
};

// map to solver interrupts
struct gv_int {
	GMAP_VHEADER(
			uint32_t handle;
	);
};

struct gmap_model {
	const char *name;
	struct model *mod;
};

void gmap_hook_main(struct fhk_graph *G);
void gmap_hook_subgraph(struct fhk_graph *G, struct fhk_graph *H);
void gmap_bind(struct fhk_graph *G, unsigned idx, struct gv_any *v);
void gmap_unbind(struct fhk_graph *G, unsigned idx);
void gmap_bind_model(struct fhk_graph *G, unsigned idx, struct gmap_model *m);
void gmap_unbind_model(struct fhk_graph *G, unsigned idx);
