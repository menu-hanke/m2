#pragma once

/* fhk public header */

#include "../mem.h"

#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>
#include <assert.h>

// smallest types that fit (see def.h)
typedef uint16_t fhk_grp;
typedef int16_t  fhk_idx;
typedef uint16_t fhk_nidx;
typedef uint16_t fhk_inst;
typedef int32_t  fhk_map;

typedef struct fhk_eref {
	fhk_idx idx;
	fhk_inst inst;
} fhk_eref;

enum {
	FHK_NINST = 0xffff, // invalid instance
	FHK_NIDX  = 0x7fff  // invalid variable/model/map
};

typedef uint16_t fhk_extmap;

// subset representation.
// note: * any non-zero subset is assumed non-empty. non-zero empty set representations
//         will cause surprises.
//       * size and interval number are the amount if items remaining after current.
//         0 is valid and means this is the last one.
//       * intervals pointed to by a complex subset must be non-overlapping and sorted
//         in increasing order.
//
//             +--------+--------+--------+--------+
//             | 63..48 | 47..32 | 31..16 | 15..0  |
// +-----------+--------+--------+--------+--------+
// | empty set |   0    |   0    |   0    |   0    |
// +-----------+--------+--------+--------+--------+
// | interval  |   -1   | -size  | first  |   0    |
// +-----------+--------+--------+--------+--------+
// | complex   |     interval pointer     | n.ival |
// +-----------+--------------------------+--------+
typedef uint64_t fhk_subset;

// ---- error handling ----------------------------------------

// error info. 48 bits to fit fhk_status.
//
// +--------+--------+--------+-------+-------+
// | 47..32 | 31..16 | 15..12 | 11..8 |  7..0 |
// +--------+--------+--------+-------+-------+
// | info 2 | info 1 | tag 2  | tag 1 | ecode |
// +--------+--------+--------+-------+-------+
typedef uint64_t fhk_ei;

#define FHK_ECODE(ei)  ((ei) & 0xff)
#define FHK_ETAG1(ei)  (((ei) >> 8) & 0xf)
#define FHK_ETAG2(ei)  (((ei) >> 12) & 0xf)
#define FHK_EINFO1(ei) (((ei) >> 16) & 0xffff)
#define FHK_EINFO2(ei) (((ei) >> 32) & 0xffff)

enum {
	// ecode
	FHKE_NYI = 1,    // s      not yet implemed
	FHKE_INVAL,      // s b    user value was stupid
	FHKE_OVERWRITE,  // s      overwrite not allowed
	FHKE_DEPTH,      // s      max recursion depth
	FHKE_NVALUE,     // s      no value
	FHKE_MEM,        // spb    failed to allocate memory
	FHKE_CHAIN,      // sp     no chain with finite cost

	// tag
	FHKEI_I = 1,     //        index
	FHKEI_J,         //        instance
	FHKEI_G,         //        group
	FHKEI_P          //        usermap
};

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
	FHKS_VREF,               // s_vref                  call fhkS_give(_all)
	FHKS_MODCALL,            // s_modcall               write values to return edges [np, np+nr)
	FHK_ERROR                // s_ei                    stop
};

// each field here must fit in 48 bits
typedef union fhk_sarg {
	uint64_t u64;

	// FHKS_VREF
	fhk_eref s_vref;

	// FHKS_MAPCALL(I)
	struct {
		fhk_eref mref;
		fhk_subset *ss;
	} *s_mapcall;

	// FHKS_MODCALL
	struct {
		uint8_t np, nr;
		fhk_eref mref;
		struct {
			void *p;
			size_t n;
		} edges[];
	} *s_modcall;

	// FHKS_SHAPE
	fhk_grp s_group;

	// FHK_ERROR
	fhk_ei s_ei;
} fhk_sarg;

static_assert(sizeof(fhk_sarg) == sizeof(uint64_t));

#define fhk_vref    typeof(((fhk_sarg *)0)->s_vref)
#define fhk_modcall typeof(*((fhk_sarg *)0)->s_modcall)
#define fhk_mcedge  typeof(*((fhk_modcall *)0)->edges)
#define fhk_mapcall typeof(*((fhk_sarg *)0)->s_mapcall)

// ---- solver structures ----------------------------------------

// constraints

typedef union {
	float f32;
	double f64;
	uint64_t u64;
} fhk_shvalue;

enum {
	// cst.op                      action(x)
	// ------                      ---------
	FHKC_GEF32,                 // x->f32 >= arg.f32
	FHKC_LEF32,                 // x->f32 <= arg.f32
	FHKC_GEF64,                 // x->f64 >= arg.f64
	FHKC_LEF64,                 // x->f64 <= arg.f64
	FHKC_U8_MASK64              // ((1ULL << x->u8) & arg.u64) != 0
};

// mappings

enum {
	FHKM_IDENT = 0xffff,
	FHKM_SPACE = 0xfffe,
	// usermap: your id (at most G_MAXUMAP)
};

// ---- solver request ----------------------------------------

enum {
	// flag                  action
	// ----------------      ----------
	FHKF_NPACK = 0x1,     // don't pack return buffer, use it as solver memory
};

typedef struct fhk_req {
	fhk_idx idx;
	uint8_t flags;
	fhk_subset ss;
	void *buf;
} fhk_req;

// ---- subgraph selection ----------------------------------------

// fhk_prune flags
enum {
	// flag               action
	// --------------     -------------------
	FHKF_GIVEN  = 0x1,   //  >v     pretend this variable is given -- delete all models that return it
	FHKF_SKIP   = 0x2,   // <>vm    skip this variable/model from the graph completely
	FHKF_SELECT = 0x4,   // <>vm    force inclusion of this var/model w/ full chain

};

// ---- def objects ----------------------------------------

typedef uint64_t fhk_obj;

enum {
	FHKO_ERROR,
	FHKO_MODEL,
	FHKO_VAR,
	FHKO_SHADOW
};

#define FHKO_TAG(obj) ((obj) >> 60)

// ------------------------------------------------------------

typedef struct fhk_graph fhk_graph;
typedef struct fhk_solver fhk_solver;
typedef struct fhk_def fhk_def;
typedef struct fhk_prune fhk_prune;
typedef float fhk_cbound[2];

fhk_solver *fhk_create_solver(fhk_graph *G, arena *arena, size_t nv, fhk_req *rq);
fhk_status fhk_continue(fhk_solver *S);

void fhkS_shape(fhk_solver *S, fhk_grp group, fhk_inst size);
void fhkS_shape_table(fhk_solver *S, fhk_inst *shape);
void fhkS_give(fhk_solver *S, fhk_idx xi, fhk_inst inst, void *vp);
void fhkS_give_all(fhk_solver *S, fhk_idx xi, void *vp);

// inspection functions (this is a private api and should probably be moved in its own file).
// don't rely on these, they are only exposed for debugging.
float fhkI_cost(fhk_solver *S, fhk_idx idx, fhk_inst inst);
fhk_inst fhkI_shape(fhk_solver *S, fhk_grp group);
fhk_eref fhkI_chain(fhk_solver *S, fhk_idx xi, fhk_inst inst);
void *fhkI_value(fhk_solver *S, fhk_idx xi, fhk_inst inst);
fhk_graph *fhkI_G(fhk_solver *S);

fhk_prune *fhk_create_prune(fhk_graph *G);
void fhk_destroy_prune(fhk_prune *P);
uint8_t *fhk_prune_flags(fhk_prune *P);
fhk_cbound *fhk_prune_bounds(fhk_prune *P);
fhk_ei fhk_prune_run(fhk_prune *P);

fhk_def *fhk_create_def();
void fhk_destroy_def(fhk_def *D);
size_t fhk_graph_size(fhk_def *D);
fhk_idx fhk_graph_idx(fhk_def *D, fhk_obj obj);
fhk_graph *fhk_build_graph(fhk_def *D, void *p);
void fhk_destroy_graph(fhk_graph *G);
fhk_obj fhk_def_add_model(fhk_def *D, fhk_grp group, float k, float c, float cmin);
fhk_obj fhk_def_add_var(fhk_def *D, fhk_grp group, uint16_t size, float cdiff);
fhk_obj fhk_def_add_shadow(fhk_def *D, fhk_obj var, uint8_t guard, fhk_shvalue arg);
fhk_ei fhk_def_add_param(fhk_def *D, fhk_obj model, fhk_obj var, fhk_extmap map);
fhk_ei fhk_def_add_return(fhk_def *D, fhk_obj model, fhk_obj var, fhk_extmap map);
fhk_ei fhk_def_add_check(fhk_def *D, fhk_obj model, fhk_obj shadow, fhk_extmap map, float penalty);

void fhk_set_dsym(fhk_graph *G, const char **dsym);
bool fhk_is_debug();
