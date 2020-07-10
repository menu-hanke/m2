#pragma once

#include <stdint.h>
#include <assert.h>

// edge maps
#define MAP_TAG(map) ((map)>>30)
#define TAG_MAP(tag) ((tag)<<30)
#define UMAP_INVERSE (1 << 29)
#define UMAP_INDEX   0xffff

// model flags
#define M_NORETBUF 0x1

// variable is given <==> no models
// note: use this only for debugging (eg asserts).
//       for graph algorithms use the edge ordering.
#define V_GIVEN(x)    ((x)->n_mod == 0)
#define V_COMPUTED(x) (!V_GIVEN(x))

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
