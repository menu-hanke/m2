#pragma once

// fhk shared internal definitions

#include "fhk.h"

#include <stdint.h>
#include <assert.h>

typedef struct {
	fhk_idx idx;
	fhk_map map;
	uint8_t ex;
} fhk_edge;

typedef struct {
	fhk_idx idx;
	fhk_map map;
	uint8_t flags;
	float penalty;
} fhk_shedge;

// shadows:             shadows [p_shadow, 0)
// computed parameters: params  [0, p_cparam)            ex: original edge idx
// given parameters:    params  [p_cparam, p_param)      ex: original edge idx
// returns:             returns [0, p_return)            ex: original edge idx
#define FHK_MODEL_BW          \
	union { fhk_edge *params; fhk_shedge *shadows; }; \
	fhk_grp group;            \
	int8_t p_shadow;          \
	uint8_t p_cparam;         \
    uint8_t p_param;          \
	uint8_t p_return;         \
	uint8_t flags;            \
	/* uint16_t unused */     \
	float k, c

struct fhk_model {
	FHK_MODEL_BW;              // must be first
	float ki, ci;
	float cmin;
	// uint32_t unused
	fhk_edge *returns;
};

struct fhk_var {
	fhk_edge *models;          // ex: inverse edge index
	fhk_edge *fwds;
	fhk_grp group;
	uint8_t n_mod;
	uint16_t size;
	uint16_t n_fwd;
	// uint16_t unused
};

struct fhk_shadow {
	fhk_shvalue arg;
	fhk_idx xi;
	fhk_grp group;
	uint8_t flags;
	uint8_t guard;
	// uint8_t + uint16_t unused
	uint64_t unused;
};

static_assert(sizeof(struct fhk_var) == sizeof(struct fhk_shadow));

struct fhk_graph {
	struct fhk_model models[0];

	fhk_nidx nv; // variable count
	fhk_nidx nx; // variable-like count (variables+shadows)
	fhk_nidx nm; // model count
	fhk_grp ng;  // group count
	fhk_nmap nkmap; // constant map count (including groups)
	fhk_nmap nimap; // nonconstant map count
	fhk_grp *umap_assoc; // nonconstant umap source group association

#if FHK_DEBUG
	const char **dsym; // this is only meant for debugging fhk itself - not your graph
#endif

	union {
		struct fhk_shadow shadows[0];
		struct fhk_var vars[0];
	};
};

// model flags
#define M_NORETBUF 0x1

// shadow flags
#define W_COMPUTED 0x1

#define ISVI(xi) ((xi) >= 0)
#define ISMI(mi) ((mi) < 0)

// variable is given <==> no models
// note: use this only for debugging (eg asserts).
//       for graph algorithms use the edge ordering.
#define V_GIVEN(x)    ((x)->n_mod == 0)
#define V_COMPUTED(x) (!V_GIVEN(x))

// graph size
#define G_GRPBITS    7        /* bits per group size */
#define G_IDXBITS    15       /* bits per index (var/model) */
#define G_MAXIDX     0x7ffe   /* max valid (positive) index */
#define G_INSTBITS   16       /* bits per instance */
#define G_MAXINST    0xfffe   /* max valid instance */
#define G_EDGEBITS   8        /* bits per edge count */
#define G_MAXEDGE    0x7f     /* max (positive) edge */
#define G_MAXFWDE    0xffff   /* max v->m forward edge (n_fwd) */
#define G_MAXMODE    0xff     /* max v->m backward edge (n_mod) */
#define G_UMAPBITS   8        /* bits per user mapping */
#define G_MINUMAP    ((int8_t)0x81) /* min valid user mapping */
#define G_MAXUMAP    0x7f     /* max valid user mapping */

static_assert(8*sizeof(fhk_grp) >= G_GRPBITS);
static_assert(8*sizeof(fhk_idx) >= G_IDXBITS);
static_assert((1<<8*sizeof(fhk_inst)) > G_MAXINST);
static_assert(8*sizeof(fhk_map) >= G_UMAPBITS);

// mappings
#define MAP_IDENT           ((int8_t)0x80) /* identity map. adjust if you change G_UMAPBITS or G_MINUMAP */
#define MAP_SPACE(group)    (group)      /* space map - this is just the group number */
#define MAP_UMAP(map,ng)    ((map) + (((map) >= 0) ? (ng) : 0)) /* usermap: const maps are offsetted by space maps */
#define MAP_ISCONST(map)    ((map) >= 0) /* mapped set doesn't depend on instance in source group */
#define MAP_ISNONCONST(map) ((map) < 0)  /* mapped set depends on instance */
#define MAP_ISUSER(map,ng)  ((map) != MAP_IDENT && ((uint8_t)(map)) < (ng)) /* is it a user map? */

// error handling
#define E_META(n,f,x)       ((FHKEI_##f << (4*((n)+1))) | ((uint64_t)(x) << (16*(n))))

typedef uint64_t xgrp;   // group
typedef int64_t  xidx;   // index
typedef uint64_t xinst;  // instance
typedef int64_t  xmap;   // mapping

#define min(a, b) ({ typeof(a) _a = (a); typeof(b) _b = (b); _a < _b ? _a : _b; })
#define max(a, b) ({ typeof(a) _a = (a); typeof(b) _b = (b); _a > _b ? _a : _b; })
#define costf(m, S) ({ struct fhk_model *_m = (m); _m->k + _m->c*(S); })
#define costf_invS(m, cost) ({ struct fhk_model *_m = (m); _m->ki + _m->ci*(cost); })

#if FHK_DEBUG
const char *fhk_dsym(struct fhk_graph *G, xidx idx);
#endif
