#pragma once

#include "fhk.h"

#include <stdint.h>

typedef struct {
	fhk_idx idx;
	uint8_t edge_param;        // solver
	// uint8_t size ? it's free real estate here
	fhk_map map;
} fhk_edge;

struct fhk_check {
	fhk_edge edge;
	struct fhk_cst cst;
};

static_assert(sizeof(fhk_edge) == sizeof(uint64_t));

struct fhk_model {
	fhk_grp group;
	uint8_t n_param;
	uint8_t n_cparam;          // solver
	uint8_t n_return;
	uint8_t n_check;
	uint8_t n_ccheck;          // solver
	uint8_t flags;
	float k, c;
	float ki, ci;              // solver
	fhk_edge *params;          // computed parameters in [0, n_cparam), given in [n_cparam, n_param)
	                           // edge_param: model edge index (before reordering)
	fhk_edge *returns;
	struct fhk_check *checks;  // computed checks in [0, n_ccheck), given in [n_ccheck, n_check)
};

struct fhk_var {
	fhk_grp group;
	uint16_t size;
	uint16_t n_fwd;
	uint8_t n_mod;             // TODO: verify no overflow when building graph
	fhk_edge *models;          // edge_param: corresponding return edge idx
	fhk_edge *fwd_models;
};

struct fhk_graph {
	fhk_idx nv, nm, nu;
	fhk_grp ng;                // solver
	struct fhk_var *vars;
	struct fhk_model *models;

#if FHK_DEBUG
	// this is only meant for debugging fhk itself - not your graph
	struct {
		const char **v_names;
		const char **m_names;
	} dsym;
#endif
};
