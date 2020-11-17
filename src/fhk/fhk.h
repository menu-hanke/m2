#pragma once

/* fhk public header */

#include "../mem.h"

#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>
#include <assert.h>

// smallest types that fit (see def.h)
typedef uint16_t fhk_grp;
typedef uint16_t fhk_idx;
typedef uint16_t fhk_inst;

//       tag
//      ^^^^^
//      00 01 02 03 04 05 06 07 08 09 0A 0B 0C 0D 0E 0F 10 11 12 13 14 15 16 17 18 19 1A 1B 1C 1D 1E 1F
// user  0  0  i [----- source group (13 bits) -------] [----------- map index (16 bits) -------------]
// ident 0  1
// space 1  0                                            0  0  0 [----- target group (13 bits) -------]
typedef uint32_t fhk_map;
#define FHK_TAG_MAP(tag) (((tag)<<30) & 0xffffffff)
#define FHK_MAP_TAG(map) ((map)>>30)

typedef int64_t fhk_subset;
#define FHK_RANGE(from, to) (((to)<<16)|(from))
#define FHK_SS(n,ranges)    ((fhk_subset)(((n-1))<<49)|(1ULL<<48)|((uintptr_t)(ranges)))

// ---- solver status ----------------------------------------

typedef uint64_t fhk_status;

#define FHK_CODE(s) ((s) & 0xffff)
#define FHK_ARG(s)  ((fhk_sarg) {.u64=(s)>>16})

enum {
	// FHK_CODE(status)         FHK_ARG(status)         action
	// ----------------         ---------------         ------
	FHK_OK = 0,              //                         stop
	FHKS_SHAPE,              // s_shape                 call fhkS_shape(_table)
	FHKS_MAPCALL,            // s_mapcall               write mapping to s_mapcall->ss
	FHKS_MAPCALLI,           // s_mapcall               write inverse mapping to s_mapcall->ss
	FHKS_GVAL,               // s_gval                  call fhkS_give(_all)
	FHKS_MODCALL,            // s_modcall               write values to return edges [np, np+nr)
	FHK_ERROR                // s_ei                    stop
};

// each field here must fit in 48 bits
typedef union fhk_sarg {
	uint64_t u64;

	// FHKS_GVAL
	struct {
		fhk_idx idx;
		fhk_inst instance;
	} s_gval;

	// FHKS_MAPCALL(I)
	struct {
		fhk_idx idx;
		fhk_inst instance;
		fhk_subset *ss;
	} *s_mapcall;

	// FHKS_MODCALL
	struct {
		uint8_t np, nr;
		fhk_idx idx;
		fhk_inst instance;
		struct {
			void *p;
			size_t n;
		} edges[];
	} *s_modcall;

	// FHKS_SHAPE
	fhk_grp s_group;

	// FHK_ERROR
	struct {
		unsigned ecode : 4;
		unsigned where : 4;
		unsigned tag1  : 4;
		unsigned tag2  : 4;
		unsigned v1    : 16;
		unsigned v2    : 16;
	} s_ei;
} fhk_sarg;

static_assert(sizeof(fhk_sarg) == sizeof(uint64_t));

#define fhk_gval    typeof(((fhk_sarg *)0)->s_gval)
#define fhk_modcall typeof(*((fhk_sarg *)0)->s_modcall)
#define fhk_mcedge  typeof(*((fhk_modcall *)0)->edges)
#define fhk_mapcall typeof(*((fhk_sarg *)0)->s_mapcall)
#define fhk_ei      typeof(*((fhk_sarg *)0)->s_ei)

enum {
	// s_ei.ecode
	FHKE_NYI = 1,    // not yet implemented
	FHKE_INVAL,      // user gave something stupid
	FHKE_REWRITE,    // rewrite of given value
	FHKE_DEPTH,      // max recursion depth exceeded
	FHKE_VALUE,      // value not given
	FHKE_MEM,        // failed to allocate memory
	FHKE_CHAIN,      // no chain with finite cost

	// s_ei.where
	FHKF_SOLVER = 1, // main solver
	FHKF_CYCLE,      // cycle solver
	FHKF_SHAPE,      // shape table
	FHKF_GIVE,       // given variable
	FHKF_MEM,        // external memory
	FHKF_MAP,        // mapping
	FHKF_SCRATCH,    // scratch buffer

	// s_ei.tag{1,2} -- s_ei.v{1,2} is the corresponding value
	FHKEI_NONE = 0,
	FHKEI_G,         // group
	FHKEI_V,         // var idx
	FHKEI_M,         // model idx
	FHKEI_P,         // map idx
	FHKEI_I,         // instance
};

// ---- solver structures ----------------------------------------

// constraints

typedef struct fhk_cst {
	float penalty;
	uint8_t op;
	union {
		float f32;
		double f64;
		uint64_t u64;
	} arg;
} fhk_cst;

#define fhk_carg typeof(((fhk_cst *)0)->arg)

enum {
	// cst.op                      action(x)
	// ------                      ---------
	FHKC_GEF64,                 // x->f64 >= arg.f64
	FHKC_LEF64,                 // x->f64 <= arg.f64
	FHKC__NUM_FP,
	FHKC_GEF32 = FHKC__NUM_FP, // x->f32 >= arg.f32
	FHKC_LEF32,                // x->f32 <= arg.f32

	FHKC_U8_MASK64,            // ((1ULL << x->u8) & arg.u64) != 0
	FHKC__NUM
};

// mappings

enum {
	// mapping                          action
	// ---------------------------      -----------------
	FHKM_USER  = FHK_TAG_MAP(0x00),     // yield FHKS_MAPCALL(I)
	FHKM_IDENT = FHK_TAG_MAP(0x01),     // i -> {i}
	FHKM_SPACE = FHK_TAG_MAP(0x02)      // i -> X
};

// ---- subgraph selection ----------------------------------------

typedef struct fhk_subgraph {
	fhk_idx *r_vars;
	fhk_idx *r_models;
} fhk_subgraph;

enum {
	// v_flags             action
	// -------------       ----------
	FHKR_GIVEN = 0x1,   // will be given in the subgraph
	FHKR_ROOT  = 0x2,   // must include in subgraph (selection root)

	// r_vars/r_models
	FHKR_SKIP  = 0xffff // skipped from subgraph
};

// ---- graph builder ----------------------------------------

enum {
	FHKDE_MEM = 1,  // failed to allocate memory
	FHKDE_INVAL,    // invalid value
	FHKDE_IDX       // graph is too large (ran out of indices)
};

// ------------------------------------------------------------

typedef struct fhk_graph fhk_graph;
typedef struct fhk_solver fhk_solver;
typedef struct fhk_def fhk_def;

typedef struct fhk_req {
	fhk_idx idx;
	fhk_subset ss;
	void *buf;
} fhk_req;

fhk_solver *fhk_create_solver(fhk_graph *G, arena *arena, size_t nv, fhk_req *rq);
fhk_status fhk_continue(fhk_solver *S);

void fhkS_shape(fhk_solver *S, fhk_grp group, fhk_inst size);
void fhkS_shape_table(fhk_solver *S, fhk_inst *shape);
void fhkS_give(fhk_solver *S, fhk_idx xi, fhk_inst inst, void *vp);
void fhkS_give_all(fhk_solver *S, fhk_idx xi, void *vp);
void fhkS_use_mem(fhk_solver *S, fhk_idx xi, void *vp);

fhk_subgraph *fhk_reduce(fhk_graph *G, arena *arena, uint8_t *v_flags, fhk_idx *fail);

fhk_def *fhk_create_def();
void fhk_destroy_def(fhk_def *D);
void fhk_reset_def(fhk_def *D);
size_t fhk_graph_size(fhk_def *D);
fhk_graph *fhk_build_graph(fhk_def *D, void *p);
int fhk_def_add_model(fhk_def *D, fhk_idx *idx, fhk_grp group, float k, float c);
int fhk_def_add_var(fhk_def *D, fhk_idx *idx, fhk_grp group, uint16_t size);
int fhk_def_add_param(fhk_def *D, fhk_idx model, fhk_idx var, fhk_map map);
int fhk_def_add_return(fhk_def *D, fhk_idx model, fhk_idx var, fhk_map map);
int fhk_def_add_check(fhk_def *D, fhk_idx model, fhk_idx var, fhk_map map, fhk_cst *cst);

size_t fhk_subgraph_size(fhk_graph *G, fhk_subgraph *S);
fhk_graph *fhk_build_subgraph(fhk_graph *G, fhk_subgraph *S, void *p);

void fhk_set_dsym(fhk_graph *G, const char **v_names, const char **m_names);
bool fhk_is_debug();
