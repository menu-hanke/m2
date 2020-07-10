#pragma once

#include "fhk.h"

#include <stdint.h>

// map      value
// user  -> 0 0 i                        |- LUT index (16 bits) --|  # i: inverse bit
// ident -> 0 1
// space -> 1 0                          |--- group (16 bits) ----|
// range -> 1 1 |---- end (15 bits) ----| |--- start (15 bits) ---|
typedef struct {
	uint16_t idx;
	uint8_t edge_param;        // solver
	// uint8_t size ? it's free real estate here
	uint32_t map;
} fhk_edge;

struct fhk_check {
	fhk_edge edge;
	float penalty;
	int op;
	fhk_arg arg;
};

struct fhk_model {
	uint16_t group;
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
	fhk_arg udata;
};

struct fhk_var {
	uint16_t group;
	uint16_t size;
	uint16_t n_fwd;
	uint8_t n_mod;             // TODO: verify no overflow when building graph
	fhk_edge *models;          // edge_param: corresponding return edge idx
	fhk_edge *fwd_models;
	fhk_arg udata;
};

struct fhk_umap {
	uint16_t group[2]; // [0] = model group, [1] = var group (inverse)
	fhk_arg udata;
};

struct fhk_graph {
	uint16_t nv, nm, nu;
	uint16_t ng;               // solver
	struct fhk_var *vars;
	struct fhk_model *models;
	struct fhk_umap *umaps;

#ifdef FHK_DEBUG
	// this is only meant for debugging fhk itself - not your graph,
	// which is why its behind the ifdef
	struct {
		const char **v_names;
		const char **m_names;
	} dsym;
#endif
};
