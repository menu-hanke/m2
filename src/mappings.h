#pragma once

#include "graph.h"
#include "vec.h"
#include "type.h"
// TODO: grid.h also

#include <stdint.h>
#include <stdbool.h>

enum {
	FHKM_MAP_DATA = FHKG_MAPPINGS_START,
	/* FHKM_MAP_GRID, */
	FHKM_MAP_VEC
};

struct fhkM_dataV {
	FHKG_MAPPINGV();
	void *ref;
};

// TODO: fhkM_gridV

// maps vector component values to fhk variables:
//
//                  band ---v                         *idx
//  bind->bands: . . . [ ] [*] [ ] . . .               |
//                          |                          v
//                          band->data ----> [][][][][][  + ][][][][][][][]
//                                                        ^- offset
struct fhkM_vecV {
	FHKG_MAPPINGV(
			uint16_t offset;
			uint16_t stride;
			uint16_t band;
	);
	struct vec **vec;
	unsigned *idx;
};

struct fhkM_iter_range {
	struct fhkG_map_iter iter;
	unsigned len, idx;
};

void fhkM_range_init(struct fhkM_iter_range *iv);

tvalue *fhkM_data_read(struct fhkM_dataV *v);
tvalue *fhkM_vec_read(struct fhkM_vecV *v, uint64_t flags);
