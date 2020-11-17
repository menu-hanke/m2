#pragma once

#include "fhk.h"

#include <stdint.h>
#include <assert.h>

// model flags
#define M_NORETBUF 0x1

// variable is given <==> no models
// note: use this only for debugging (eg asserts).
//       for graph algorithms use the edge ordering.
#define V_GIVEN(x)    ((x)->n_mod == 0)
#define V_COMPUTED(x) (!V_GIVEN(x))

// graph size
#define G_GRPBITS    13
#define G_MAXGRP     ((1 << G_GROUP_BITS) - 1)
#define G_IDXBITS    16
// 0xffff is reserved for missing shape / exclusive range end
#define G_MAXIDX     0xfffe
#define G_MAXINST    0xfffe
#define G_MAXEDGE    0xff

static_assert(8*sizeof(fhk_grp) >= G_GRPBITS);
static_assert(8*sizeof(fhk_idx) >= G_IDXBITS);
static_assert((1<<8*sizeof(fhk_inst)) > G_MAXINST);
static_assert(8*sizeof(fhk_map) == (2 + 1 + G_GRPBITS + G_IDXBITS));

#define UMAP_INVERSE    (1 << 29)
#define UMAP_INDEX      0xffff
#define UMAP_GROUP(map) (((map)>>16) & 0x1fff)
#define GROUP_UMAP(grp) ((grp)<<16)
#define SMAP_GROUP      0xffff

// these are just markers to make the code easier to read
typedef uint64_t xgrp;   // group
typedef uint64_t xidx;   // index
typedef uint64_t xinst;  // instance
typedef uint32_t xmap;   // mapping

#define min(a, b) ({ typeof(a) _a = (a); typeof(b) _b = (b); _a < _b ? _a : _b; })
#define max(a, b) ({ typeof(a) _a = (a); typeof(b) _b = (b); _a > _b ? _a : _b; })
#define costf(m, S) ({ struct fhk_model *_m = (m); _m->k + _m->c*(S); })
#define costf_invS(m, cost) ({ struct fhk_model *_m = (m); _m->ki + _m->ci*(cost); })

#ifdef FHK_DEBUG
const char *fhk_Dvar(struct fhk_graph *G, xidx vi);
const char *fhk_Dmodel(struct fhk_graph *G, xidx mi);
#endif

// max solver recursive calls
#ifndef FHK_MAX_STK
#define FHK_MAX_STK 32
#endif

// coroutine stack size
//#define FHK_CO_STACK 4*1024*1024
#ifndef FHK_CO_STACK
#define FHK_CO_STACK (65536 + 1024*FHK_MAX_STK)
#endif
