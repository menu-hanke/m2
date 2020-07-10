#pragma once

/* fhk public header */

#include "../mem.h"

#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>
#include <assert.h>

// code                      A                B                C                X
// ------                    ------           ------           -----            -----
// FHK_OK
// FHK_ERROR                 error code       flags (FHKEI_*)                   struct fhk_ei *
// FHKS_SHAPE                                                                   group
// FHKS_MAPPING              |------ struct fhks_mapping *marg -----|           map userdata
// FHKS_MAPPING_INVERSE      |------ struct fhks_mapping *marg -----|           map userdata
// FHKS_COMPUTE_GIVEN        var              instance                          var userdata
// FHKS_COMPUTE_MODEL        |------- struct fhks_cmodel *cmarg ----|           model userdata
typedef struct { uint64_t r[2]; } fhk_status;

#define FHK_CODE(s) ((s).r[0] & 0xffff)
#define FHK_A(s)    ((s).r[0] >> 48)
#define FHK_B(s)    (((s).r[0] >> 32) & 0xffff)
#define FHK_C(s)    (((s).r[0] >> 16) & 0xffff)
#define FHK_ABC(s)  ((s).r[0] >> 16)
#define FHK_X(s)    ((s).r[1])

typedef int64_t fhk_subset;

struct fhks_cmodel {
	uint8_t np, nr;
	uint16_t instance;
	struct {
		void *p;
		size_t n;
	} edges[];
};

struct fhks_mapping {
	uint16_t instance;
	fhk_subset *ss;
};

struct fhk_ei {
	const char *desc;
	uint16_t g, v, m, i;
};

enum {
	FHKEI_G   = 0x01,
	FHKEI_V   = 0x02,
	FHKEI_M   = 0x04,
	FHKEI_I   = 0x08
};

enum {
	FHKE_NYI   = 0,  // not yet implemented
	FHKE_INVAL,      // user gave something stupid
	FHKE_DEPTH,      // max recursion depth exceeded
	FHKE_VALUE,      // value not given
	FHKE_MEM,        // failed to allocate memory
	FHKE_CHAIN,      // no chain with finite cost

	FHK_OK     = 0,
	FHKS_MAPPING,
	FHKS_MAPPING_INVERSE,
	FHKS_COMPUTE_GIVEN,
	FHKS_COMPUTE_MODEL,
	FHKS_SHAPE,
	FHK_ERROR
};

static_assert(FHKS_MAPPING == 1 && FHKS_MAPPING_INVERSE == 2);

enum {
	FHKC_GEF64,
	FHKC_LEF64,
	FHKC_GEF32,
	FHKC_LEF32,
	// GT, LT are implemented with epsilon
	FHKC_U8_MASK64
};

enum {
	FHK_MAP_USER,
	FHK_MAP_IDENT,
	FHK_MAP_SPACE,
	FHK_MAP_RANGE
};

enum {
	// var flags
	FHK_GIVEN = 0x1,
	FHK_ROOT  = 0x2,

	// reduce call flags
	FHK_REASSIGN_GROUPS = 0x1, // TODO
	
	FHK_SKIP  = 0xffff
};

typedef struct fhk_graph fhk_graph;
typedef struct fhk_solver fhk_solver;
typedef struct fhk_def fhk_def;

#define FHK_RANGE(from, to) (((to)<<16)|(from))
#define FHK_SS1(range)      ((fhk_subset)((1ULL<<48)|(range)))
#define FHK_SS(n,ranges)    ((fhk_subset)((n)<<48)|((uintptr_t)(ranges)))

typedef union {
	float f32;
	double f64;
	uint64_t u64;
	void *p;
	fhk_subset ss;
} fhk_arg;

struct fhk_req {
	uint16_t idx;
	fhk_subset ss;
	void *buf;
};

struct fhk_subgraph {
	uint16_t *r_vars;
	uint16_t *r_models;
	uint16_t *r_maps;
};

fhk_solver *fhk_create_solver(fhk_graph *G, arena *arena, size_t nv, struct fhk_req *rq);
fhk_status fhk_continue(fhk_solver *S);

fhk_status fhkS_shape(fhk_solver *S, size_t group, int16_t size);
fhk_status fhkS_shape_table(fhk_solver *S, int16_t *shape);
fhk_status fhkS_give(fhk_solver *S, size_t xi, size_t inst, void *vp);
fhk_status fhkS_give_all(fhk_solver *S, size_t xi, void *vp);
fhk_status fhkS_use_mem(fhk_solver *S, size_t xi, void *vp);

struct fhk_subgraph *fhk_reduce(fhk_graph *G, arena *arena, uint8_t *v_flags, uint16_t *fail);

fhk_def *fhk_create_def();
void fhk_destroy_def(fhk_def *D);
void fhk_reset_def(fhk_def *D);
size_t fhk_graph_size(fhk_def *D);
fhk_graph *fhk_build_graph(fhk_def *D, void *p);
uint16_t fhk_def_add_model(fhk_def *D, uint16_t group, float k, float c, fhk_arg udata);
uint16_t fhk_def_add_var(fhk_def *D, uint16_t group, uint16_t size, fhk_arg udata);
void fhk_def_add_param(fhk_def *D, uint16_t model, uint16_t var, int map, fhk_arg arg);
void fhk_def_add_return(fhk_def *D, uint16_t model, uint16_t var, int map, fhk_arg arg);
void fhk_def_add_check(fhk_def *D, uint16_t model, uint16_t var, int map, fhk_arg arg,
		int op, fhk_arg oparg, float penalty);

size_t fhk_subgraph_size(fhk_graph *G, struct fhk_subgraph *S);
fhk_graph *fhk_build_subgraph(fhk_graph *G, struct fhk_subgraph *S, void *p);

void fhk_set_dsym(fhk_graph *G, const char **v_names, const char **m_names);
bool fhk_is_debug();
