#include "fhk.h"
#include "graph.h"
#include "def.h"

#include "../def.h"

#include <stdlib.h>
#include <stdint.h>
#include <stdalign.h>
#include <stdbool.h>
#include <string.h>
#include <math.h>
#include <assert.h>

#define MAP_INVAL ((fhk_map)(~0))

struct def_model {
	uint8_t nc, nc_alloc;
	uint8_t np, np_alloc;
	uint8_t nr, nr_alloc;
	fhk_grp group;
	struct fhk_check *checks;
	fhk_edge *params;
	fhk_edge *returns;
	float k, c;
};

struct def_var {
	fhk_grp group;
	uint16_t size;
};

struct fhk_def {
	fhk_idx nv, nv_alloc;
	fhk_idx nm, nm_alloc;
	struct def_var *vars;
	struct def_model *models;
};

#define LIST_ADD(n, na, p) ({                               \
		if(UNLIKELY(*(n) >= *(na))){                        \
			typeof(*(na)) _n = *(n);                        \
			*(na) = *(na) ? 2*(*na) : 8;                    \
			*(p) = realloc(*(p), sizeof(**(p))*(*na));      \
			memset(*(p)+_n, 0, sizeof(**(p))*(*(na)-_n));   \
		}                                                   \
		*(p) + (*(n))++;                                    \
	})

#define LIST_PREALLOC(n, na, p, init) do {             \
		*(n) = 0;                                      \
		*(na) = (init);                                \
		*(p) = calloc((init), sizeof(**(p)));          \
	} while(0)

static fhk_map d_map(struct fhk_def *D, fhk_idx mi, fhk_idx xi, fhk_map map);
static fhk_map d_inverse(struct fhk_def *D, fhk_idx xi, fhk_idx mi, fhk_map map);
static void d_copy_data(struct fhk_def *D, struct fhk_graph *G);
static void d_copy_links(void **p, struct fhk_def *D, struct fhk_graph *G);

static void s_count_nodes(struct fhk_graph *G, struct fhk_subgraph *S, size_t *nv, size_t *nm);
static void s_count_links(struct fhk_graph *G, struct fhk_subgraph *S, size_t *ne, size_t *nc);
static void s_copy_data(struct fhk_graph *G, struct fhk_subgraph *S, struct fhk_graph *H);
static void s_copy_links(void **p, struct fhk_graph *G, struct fhk_subgraph *S, struct fhk_graph *H);

#ifdef FHK_DEBUG
#define DSYM_ALIGN(G, p)\
	(((G)->dsym.v_names || (G)->dsym.m_names) ? (ALIGN(p, sizeof(void *)) - p) : 0)
#define DSYM_SIZE(G, nv, nm)\
	((G->dsym.v_names ? (nv)*sizeof(void *) : 0) + (G->dsym.m_names ? (nm)*sizeof(void *) : 0))
static void s_copy_ds(const char **dest, const char **src, fhk_idx *rt, size_t n);
static void s_copy_dsyms(void **p, struct fhk_graph *G, struct fhk_subgraph *S, struct fhk_graph *H);
#else
#define DSYM_ALIGN(...) 0
#define DSYM_SIZE(...)  0
#endif

static size_t g_alloc_size(size_t nv, size_t nm, size_t ne, size_t nc);
static struct fhk_graph *g_alloc_base(void **p, fhk_idx nv, fhk_idx nm);
static void g_compute_flags(struct fhk_graph *G);
static void g_reorder_edges(struct fhk_graph *G);
static void g_compute_ng(struct fhk_graph *G);
static void g_compute_nu(struct fhk_graph *G);

struct fhk_def *fhk_create_def(){
	struct fhk_def *D = malloc(sizeof(*D));
	LIST_PREALLOC(&D->nv, &D->nv_alloc, &D->vars, 32);
	LIST_PREALLOC(&D->nm, &D->nm_alloc, &D->models, 32);
	return D;
}

void fhk_destroy_def(struct fhk_def *D){
	// this is intentionally looping to nm_alloc instead of nm; if this def is re-used then
	// there may be allocs beyond nm.
	// passing null to `free` is ok.
	for(size_t i=0;i<D->nm_alloc;i++){
		struct def_model *dm = &D->models[i];
		free(dm->checks);
		free(dm->params);
		free(dm->returns);
	}

	free(D->vars);
	free(D->models);

	free(D);
}

void fhk_reset_def(struct fhk_def *D){
	D->nv = 0;
	D->nm = 0;
}

size_t fhk_graph_size(struct fhk_def *D){
	size_t ne = 0, nc = 0;

	for(size_t i=0;i<D->nm;i++){
		struct def_model *dm = &D->models[i];
		ne += 2 * (dm->np + dm->nr);
		nc += dm->nc;
	}

	return g_alloc_size(D->nv, D->nm, ne, nc);
}

struct fhk_graph *fhk_build_graph(struct fhk_def *D, void *p){
	if(!p)
		p = malloc(fhk_graph_size(D));

#ifdef FHK_DEBUG
	void *_mem = p;
#endif

	struct fhk_graph *G = g_alloc_base(&p, D->nv, D->nm);
#ifdef FHK_DEBUG
	memset(&G->dsym, 0, sizeof(G->dsym));
#endif
	d_copy_data(D, G);
	d_copy_links(&p, D, G);

	g_compute_flags(G);
	g_reorder_edges(G);
	g_compute_ng(G);
	g_compute_nu(G);

#ifdef FHK_DEBUG
	assert(p == ALIGN(_mem, 8) + fhk_graph_size(D));
#endif

	return G;
}

int fhk_def_add_model(struct fhk_def *D, fhk_idx *idx, fhk_grp group, float k, float c){
	if(D->nm == G_MAXIDX)
		return FHKDE_IDX;

	*idx = D->nm;

	struct def_model *dm = LIST_ADD(&D->nm, &D->nm_alloc, &D->models);

	if(dm->np_alloc) dm->np = 0;
	else LIST_PREALLOC(&dm->np, &dm->np_alloc, &dm->params, 8);

	if(dm->nr_alloc) dm->nr = 0;
	else LIST_PREALLOC(&dm->nr, &dm->nr_alloc, &dm->returns, 8);

	dm->nc = 0;

	dm->group = group;
	dm->k = k;
	dm->c = c;

	return FHK_OK;
}

int fhk_def_add_var(struct fhk_def *D, fhk_idx *idx, fhk_grp group, uint16_t size){
	if(D->nv == G_MAXIDX)
		return FHKDE_IDX;

	*idx = D->nv;

	struct def_var *dv = LIST_ADD(&D->nv, &D->nv_alloc, &D->vars);
	dv->group = group;
	dv->size = size;

	return FHK_OK;
}

int fhk_def_add_param(struct fhk_def *D, fhk_idx model, fhk_idx var, fhk_map map){
	if(model >= D->nm || var >= D->nv)
		return FHKDE_INVAL;

	struct def_model *dm = &D->models[model];
	
	if(dm->np == G_MAXEDGE)
		return FHKDE_IDX;

	map = d_map(D, model, var, map);
	if(map == MAP_INVAL)
		return FHKDE_INVAL;

	*LIST_ADD(&dm->np, &dm->np_alloc, &dm->params) = (fhk_edge){
		.idx = var,
		.map = map,
		.edge_param = dm->np-1 // for param links this is the definition edge index
	};

	return FHK_OK;
}

int fhk_def_add_return(struct fhk_def *D, fhk_idx model, fhk_idx var, fhk_map map){
	if(model >= D->nm || var >= D->nv)
		return FHKDE_INVAL;

	struct def_model *dm = &D->models[model];

	if(dm->nr == G_MAXEDGE)
		return FHKDE_IDX;

	map = d_map(D, model, var, map);
	if(map == MAP_INVAL)
		return FHKDE_INVAL;

	*LIST_ADD(&dm->nr, &dm->nr_alloc, &dm->returns) = (fhk_edge){
		.idx = var,
		.map = map,
		.edge_param = 0
	};

	return FHK_OK;
}

int fhk_def_add_check(struct fhk_def *D, fhk_idx model, fhk_idx var, fhk_map map,
		struct fhk_cst *cst){

	if(model >= D->nm || var >= D->nv)
		return FHKDE_INVAL;

	struct def_model *dm = &D->models[model];

	if(dm->nc == G_MAXEDGE)
		return FHKDE_IDX;

	map = d_map(D, model, var, map);
	if(map == MAP_INVAL)
		return FHKDE_INVAL;

	if(cst->op >= FHKC__NUM)
		return FHKDE_INVAL;

	*LIST_ADD(&dm->nc, &dm->nc_alloc, &dm->checks) = (struct fhk_check){
		.edge = {
			.idx = var,
			.map = map,
			.edge_param = 0
		},
		.cst = *cst
	};

	return FHK_OK;
}

size_t fhk_subgraph_size(struct fhk_graph *G, struct fhk_subgraph *S){
	size_t nm, nv, ne, nc;
	s_count_nodes(G, S, &nv, &nm);
	s_count_links(G, S, &ne, &nc);
	size_t as = g_alloc_size(nv, nm, ne, nc);
	return as + DSYM_ALIGN(G, as) + DSYM_SIZE(G, nv, nm);
}

struct fhk_graph *fhk_build_subgraph(struct fhk_graph *G, struct fhk_subgraph *S, void *p){
	size_t nv, nm;
	s_count_nodes(G, S, &nv, &nm);

	if(!p){
		size_t ne, nc;
		s_count_links(G, S, &ne, &nc);
		size_t as = g_alloc_size(nv, nm, ne, nc);
		p = malloc(as + DSYM_ALIGN(G, as) + DSYM_SIZE(G, nv, nm));
	}

#ifdef FHK_DEBUG
	void *_mem = p;
#endif

	struct fhk_graph *H = g_alloc_base(&p, nv, nm);

	// this could technically be smaller but it doesn't matter
	H->ng = G->ng;

	s_copy_data(G, S, H);
	s_copy_links(&p, G, S, H);
#ifdef FHK_DEBUG
	s_copy_dsyms(&p, G, S, H);
#endif

	// non-given vars might have turned to given, so this needs to be recomputed
	g_reorder_edges(H);

	// some umaps might have been deleted so we may have H->nu < G->nu.
	// this would work without the recomputation (similar to ng), but it makes the solver
	// allocate less memory for umap caches
	g_compute_nu(H);

#ifdef FHK_DEBUG
	assert(p == ALIGN(_mem, 8) + fhk_subgraph_size(G, S));
#endif

	return H;
}

static fhk_map d_map(struct fhk_def *D, fhk_idx mi, fhk_idx xi, fhk_map map){
	switch(FHK_MAP_TAG(map)){
		case FHK_MAP_TAG(FHKM_USER):
			if(map >= G_MAXIDX)
				return MAP_INVAL;
			return map | GROUP_UMAP(D->models[mi].group);

		case FHK_MAP_TAG(FHKM_SPACE):
			return map | D->vars[xi].group;

		default:
			return map;
	}
}

static fhk_map d_inverse(struct fhk_def *D, fhk_idx xi, fhk_idx mi, fhk_map map){
	switch(FHK_MAP_TAG(map)){
		case FHK_MAP_TAG(FHKM_USER):
			return FHKM_USER | UMAP_INVERSE | GROUP_UMAP(D->vars[xi].group) | (map & UMAP_INDEX);

		case FHK_MAP_TAG(FHKM_SPACE):
			return FHKM_SPACE | D->models[mi].group;

		default:
			return map;
	}
}

static void d_copy_data(struct fhk_def *D, struct fhk_graph *G){
	for(size_t i=0;i<G->nv;i++){
		struct fhk_var *x = &G->vars[i];
		struct def_var *dx = &D->vars[i];

		x->group = dx->group;
		x->size = dx->size;
	}

	for(size_t i=0;i<G->nm;i++){
		struct fhk_model *m = &G->models[i];
		struct def_model *dm = &D->models[i];

		m->group = dm->group;
		m->k = dm->k;
		m->c = dm->c;

		// precompute inverse
		//     cost  = c*S + k
		//     <=> S = (cost - k)/c
		//           = ci*cost + ki
		// where
		//     ci = 1/c
		//     ki = -k/c
		//
		// c<1 is invalid so no division by zero can happen
		m->ki = -m->k/m->c;
		m->ci = 1/m->c;
	}
}

static void d_copy_links(void **p, struct fhk_def *D, struct fhk_graph *G){

	// alloc strategy:
	//     [v1 models] [v1_m1 checks] [v1_m1 params] ... [v1_mN checks] [v1_mN params] [v2 models] ...
	//     [v1 fwds] [v1_f1 returns] [v1_f2 returns] ... [v1_fN returns] [v2 fwds] [v2_f1 returns] ...
	//
	// this will make it so that there is a good chance that the candidate model's checks/params will
	// be loaded into cache when the model list for a variable is walked.
	//
	// bw/fw edges are allocated separately because they are used by different parts of the solver.
	// (main solver uses bw edges, cyclic solver uses fw edges, model evaluation may use return
	// for complex models)
	
	// the allocation proceeds as follows: *p is guaranteed to have enough space, so we use it
	// as a scratch space to construct the v->m links sequentially (m->v links don't need to be
	// constructed, just counted). then we assign the link pointers, but don't write any links
	// yet (as *p is our scratch space). then after assigning all pointers, we can construct
	// the real links. this way we avoid any extra allocations.

	// n_mod and n_fwd will count the number of models/fwds respectively.
	for(size_t i=0;i<G->nv;i++){
		struct fhk_var *x = &G->vars[i];
		x->n_mod = 0;
		x->n_fwd = 0;
	}

	// count the reverse links
	for(size_t i=0;i<G->nm;i++){
		struct def_model *dm = &D->models[i];
		struct fhk_model *m = &G->models[i];
		m->n_param = dm->np;
		m->n_return = dm->nr;
		m->n_check = dm->nc;
		m->params = NULL;
		m->returns = NULL;
		// don't need to NULL m->checks
		for(size_t j=0;j<dm->np;j++) G->vars[dm->params[j].idx].n_fwd++;
		for(size_t j=0;j<dm->nr;j++) G->vars[dm->returns[j].idx].n_mod++;
	}

	// assign v->m link pointers to the temp scratch space, we will construct them here first
	void *scratch = *p;
	for(size_t i=0;i<G->nv;i++){
		struct fhk_var *x = &G->vars[i];
		x->models = scratch;
		scratch += x->n_mod * sizeof(*x->models);
		x->fwd_models = scratch;
		scratch += x->n_fwd * sizeof(*x->fwd_models);

		// these will be the running index counters in the next step
		x->n_mod = 0;
		x->n_fwd = 0;
	}

	// construct temp v->m links (only the indices, we don't need mapping yet)
	for(size_t i=0;i<G->nm;i++){
		struct def_model *dm = &D->models[i];

		for(size_t j=0;j<dm->np;j++){
			struct fhk_var *x = &G->vars[dm->params[j].idx];
			x->fwd_models[x->n_fwd++].idx = i;
		}

		for(size_t j=0;j<dm->nr;j++){
			struct fhk_var *x = &G->vars[dm->returns[j].idx];
			x->models[x->n_mod++].idx = i;
		}
	}

	// assign backwards link pointers
	for(size_t i=0;i<G->nv;i++){
		struct fhk_var *x = &G->vars[i];
		fhk_edge *models = x->models;
		x->models = *p;
		*p += x->n_mod * sizeof(*x->models);

		for(size_t j=0;j<x->n_mod;j++){
			struct fhk_model *m = &G->models[models[j].idx];
			if(LIKELY(!m->params)){
				m->checks = *p;
				*p += m->n_check * sizeof(*m->checks);
				m->params = *p;
				*p += m->n_param * sizeof(*m->params);
			}
		}

		x->n_mod = 0; // this will be a counter
	}

	// assign forward link pointers
	for(size_t i=0;i<G->nv;i++){
		struct fhk_var *x = &G->vars[i];
		fhk_edge *fwd_models = x->fwd_models;
		x->fwd_models = *p;
		*p += x->n_fwd * sizeof(*x->fwd_models);

		for(size_t j=0;j<x->n_fwd;j++){
			struct fhk_model *m = &G->models[fwd_models[j].idx];
			if(LIKELY(!m->returns)){
				m->returns = *p;
				*p += m->n_return * sizeof(*m->returns);
			}
		}

		x->n_fwd = 0;
	}

	// assign the rest (models with no incoming edges don't get assigned in the above loops)
	for(size_t i=0;i<G->nm;i++){
		struct fhk_model *m = &G->models[i];

		if(UNLIKELY(!m->params)){
			m->checks = *p;
			*p += m->n_check * sizeof(*m->checks);
			m->params = *p;
			*p += m->n_param * sizeof(*m->params);
		}

		if(UNLIKELY(!m->returns)){
			m->returns = *p;
			*p += m->n_return * sizeof(*m->returns);
		}
	}

	// now we can construct the real links!
	for(size_t i=0;i<G->nm;i++){
		struct def_model *dm = &D->models[i];
		
		// m->v links, these can just be copied
		memcpy(G->models[i].params, dm->params, dm->np * sizeof(*dm->params));
		memcpy(G->models[i].returns, dm->returns, dm->nr * sizeof(*dm->returns));
		memcpy(G->models[i].checks, dm->checks, dm->nc * sizeof(*dm->checks));

		// v->m links, same as before but we need the inverse map

		for(size_t j=0;j<dm->np;j++){
			struct fhk_var *x = &G->vars[dm->params[j].idx];
			x->fwd_models[x->n_fwd++] = (fhk_edge){
				.idx = i,
				.map = d_inverse(D, j, i, dm->params[j].map)
			};
		}

		for(size_t j=0;j<dm->nr;j++){
			struct fhk_var *x = &G->vars[dm->returns[j].idx];
			x->models[x->n_mod++] = (fhk_edge){
				.idx = i,
				.edge_param = j,
				.map = d_inverse(D, j, i, dm->returns[j].map)
			};
		}
	}
}

static void s_count_nodes(struct fhk_graph *G, struct fhk_subgraph *S, size_t *nv, size_t *nm){
	size_t _nv = 0, _nm = 0;

	for(size_t i=0;i<G->nv;i++) _nv += !(S->r_vars[i] == FHKR_SKIP);
	for(size_t i=0;i<G->nm;i++) _nm += !(S->r_models[i] == FHKR_SKIP);

	*nv = _nv;
	*nm = _nm;
}

static void s_count_links(struct fhk_graph *G, struct fhk_subgraph *S, size_t *ne, size_t *nc){
	size_t _ne = 0, _nc = 0;

	for(size_t i=0;i<G->nm;i++){
		if(S->r_models[i] == FHKR_SKIP)
			continue;

		struct fhk_model *m = &G->models[i];

		for(size_t j=0;j<m->n_param;j++) ne += !(S->r_vars[m->params[j].idx] == FHKR_SKIP);
		for(size_t j=0;j<m->n_return;j++) ne += !(S->r_vars[m->returns[j].idx] == FHKR_SKIP);
		for(size_t j=0;j<m->n_check;j++) nc += !(S->r_vars[m->checks[j].edge.idx] == FHKR_SKIP);
	}

	*ne = 2 * _ne;
	*nc = _nc;
}

static void s_copy_data(struct fhk_graph *G, struct fhk_subgraph *S, struct fhk_graph *H){
	// !!! don't run this after s_copy_links !!!
	// !!! this overwrites link data         !!!
	
	for(size_t i=0;i<G->nv;i++){
		if(S->r_vars[i] != FHKR_SKIP)
			memcpy(&H->vars[S->r_vars[i]], &G->vars[i], sizeof(*G->vars));
	}

	for(size_t i=0;i<G->nm;i++){
		if(S->r_models[i] != FHKR_SKIP)
			memcpy(&H->models[S->r_models[i]], &G->models[i], sizeof(*G->models));
	}
}

static void s_copy_links(void **p, struct fhk_graph *G, struct fhk_subgraph *S, struct fhk_graph *H){
	// see d_copy_links for comments about the allocation strategy.
	// the difference here is that we don't need to create the temp links on a scratch space
	// because we have them already computed in G.
	
	// Note: param/return edge_params don't need to be fixed because all params and returns
	// must be preserved

	// zero these to know if we have alloc'd them
	for(size_t i=0;i<H->nm;i++){
		struct fhk_model *m = &H->models[i];
		m->n_param = 0;
		m->n_check = 0;
		m->n_return = 0;
		m->params = NULL;
		m->returns = NULL;
	}

#define copymp(_mG, _mH)                                                   \
	do {                                                                   \
		_mH->params = *p;                                                  \
		for(size_t _i=0;_i<_mG->n_param;_i++){                             \
			fhk_edge _e = _mG->params[_i];                                 \
			if(S->r_vars[_e.idx] == FHKR_SKIP)                             \
				continue;                                                  \
			_e.idx = S->r_vars[_e.idx];                                    \
			_mH->params[_mH->n_param++] = _e;                              \
		}                                                                  \
		*p += _mH->n_param * sizeof(*_mH->params);                         \
	} while(0)

#define copymc(_mG, _mH)                                                   \
	do {                                                                   \
		_mH->checks = *p;                                                  \
		for(size_t _i=0;_i<_mG->n_check;_i++){                             \
			struct fhk_check *_c = &_mG->checks[_i];                       \
			if(S->r_vars[_c->edge.idx] == FHKR_SKIP)                       \
				continue;                                                  \
			_mH->checks[_mH->n_check] = *_c;                               \
			_mH->checks[_mH->n_check].edge.idx = S->r_vars[_c->edge.idx];  \
			_mH->n_check++;                                                \
		}                                                                  \
		*p += _mH->n_check * sizeof(*_mH->checks);                         \
	} while(0)

#define copymbw(_mG, _mH)                                                  \
	do {                                                                   \
		copymp(_mG, _mH);                                                  \
		copymc(_mG, _mH);                                                  \
	} while(0)

#define copymr(_mG, _mH)                                                   \
	do {                                                                   \
		_mH->returns = *p;                                                 \
		for(size_t _i=0;_i<_mG->n_return;_i++){                            \
			fhk_edge _e = _mG->returns[_i];                                \
			if(S->r_vars[_e.idx] == FHKR_SKIP)                             \
				continue;                                                  \
			_e.idx = S->r_vars[_e.idx];                                    \
			_mH->returns[_mH->n_return++] = _e;                            \
		}                                                                  \
		*p += _mH->n_return * sizeof(*_mH->returns);                       \
	} while(0)

#define copyv(_vm, _nvm, _mv, _mvcopy)                                     \
	for(size_t i=0;i<G->nv;i++){                                           \
		if(S->r_vars[i] == FHKR_SKIP)                                      \
			continue;                                                      \
		                                                                   \
		struct fhk_var *xG = &G->vars[i];                                  \
		struct fhk_var *xH = &H->vars[S->r_vars[i]];                       \
		xH->_nvm = 0;                                                      \
		xH->_vm = *p;                                                      \
		                                                                   \
		for(size_t j=0;j<xG->_nvm;j++){                                    \
			xidx miG = xG->_vm[j].idx;                                     \
			if(S->r_models[miG] == FHKR_SKIP)                              \
				continue;                                                  \
			xH->_vm[xH->_nvm++] = xG->_vm[j];                              \
		}                                                                  \
		                                                                   \
		*p += xH->_nvm * sizeof(*xH->_vm);                                 \
		for(size_t j=0;j<xH->_nvm;j++){                                    \
			struct fhk_model *mG = &G->models[xH->_vm[j].idx];             \
			xidx miH = S->r_models[xH->_vm[j].idx];                        \
			struct fhk_model *mH = &H->models[miH];                        \
			xH->_vm[j].idx = miH;                                          \
			if(LIKELY(!mH->_mv))                                           \
				_mvcopy(mG, mH);                                           \
		}                                                                  \
	}

	copyv(models, n_mod, params, copymbw);     // backward links
	copyv(fwd_models, n_fwd, returns, copymr); // forward links

	// remaining
	for(size_t i=0;i<G->nm;i++){
		if(S->r_models[i] == FHKR_SKIP)
			continue;

		struct fhk_model *mG = &G->models[i];
		struct fhk_model *mH = &H->models[S->r_models[i]];

		if(UNLIKELY(!mH->params))  copymbw(mG, mH);
		if(UNLIKELY(!mH->returns)) copymr(mG, mH);
	}

#undef copymp
#undef copymc
#undef copymbw
#undef copymr
#undef copyv
}

#if FHK_DEBUG

static void s_copy_ds(const char **dest, const char **src, fhk_idx *rt, size_t n){
	for(size_t i=0;i<n;i++){
		if(rt[i] == FHKR_SKIP)
			continue;
		dest[rt[i]] = src[i];
	}
}

static void s_copy_dsyms(void **p, struct fhk_graph *G, struct fhk_subgraph *S, struct fhk_graph *H){
	if(G->dsym.v_names || G->dsym.m_names)
		*p = ALIGN(*p, sizeof(void *));

	if(G->dsym.v_names){
		H->dsym.v_names = *p;
		*p += H->nv * sizeof(*H->dsym.v_names);
		s_copy_ds(H->dsym.v_names, G->dsym.v_names, S->r_vars, G->nv);
	}else{
		H->dsym.v_names = NULL;
	}

	if(G->dsym.m_names){
		H->dsym.m_names = *p;
		*p += H->nm * sizeof(*H->dsym.m_names);
		s_copy_ds(H->dsym.m_names, G->dsym.m_names, S->r_models, G->nm);
	}else{
		H->dsym.m_names = NULL;
	}
}

#endif

static size_t g_alloc_size(size_t nv, size_t nm, size_t ne, size_t nc){
	// this assumes no padding between allocs.
	// everything is aligned to 8 so np.
	// note that you must also count reverse edges in ne.
	return sizeof(struct fhk_graph)
		+ nv * sizeof(struct fhk_var)
		+ nm * sizeof(struct fhk_model)
		+ ne * sizeof(fhk_edge)
		+ nc * sizeof(struct fhk_check);
}

static struct fhk_graph *g_alloc_base(void **p, fhk_idx nv, fhk_idx nm){
	*p = ALIGN(*p, alignof(struct fhk_graph));

	struct fhk_graph *G = *p;
	*p += sizeof(*G);

	G->nv = nv;
	G->nm = nm;

	G->vars = *p;
	*p += nv * sizeof(*G->vars);

	G->models = *p;
	*p += nm * sizeof(*G->models);

	return G;
}

static void g_compute_flags(struct fhk_graph *G){
	for(size_t i=0;i<G->nm;i++){
		struct fhk_model *m = &G->models[i];
		m->flags = 0;

		if(m->n_return == 1 && FHK_MAP_TAG(m->returns[0].map) == FHKM_IDENT)
			m->flags |= M_NORETBUF;
	}
}

static void g_reorder_edges(struct fhk_graph *G){
	// TODO: could do even smarter reordering here, eg. put most expensive parameters/checks first

	for(size_t i=0;i<G->nm;i++){
		struct fhk_model *m = &G->models[i];

#define swap(a, b) do { typeof(a) _a = (a); (a) = (b); (b) = _a; } while(0)

		// swap non-given params to front
		m->n_cparam = 0;
		for(size_t j=0;j<m->n_param;j++){
			struct fhk_var *x = &G->vars[m->params[j].idx];

			// not given
			if(x->n_mod){
				swap(m->params[m->n_cparam], m->params[j]);
				m->n_cparam++;
			}
		}

		// same with checks
		m->n_ccheck = 0;
		for(size_t j=0;j<m->n_check;j++){
			struct fhk_var *x = &G->vars[m->checks[j].edge.idx];

			if(x->n_mod){
				swap(m->checks[m->n_ccheck], m->checks[j]);
				m->n_ccheck++;
			}
		}
	}

#undef swap
}

static void g_compute_ng(struct fhk_graph *G){
	int32_t maxg = -1;
	
	for(size_t i=0;i<G->nv;i++) maxg = max(maxg, G->vars[i].group);
	for(size_t i=0;i<G->nm;i++) maxg = max(maxg, G->models[i].group);

	G->ng = maxg+1;
}

static void g_compute_nu(struct fhk_graph *G){
	int32_t maxu = -1;

#define checku(map) if((FHK_MAP_TAG(map) == FHKM_USER)) maxu = max(maxu, ((int32_t)(map) & UMAP_INDEX))
	// it's enough to only check m->v links, inverse maps have same index set
	for(size_t i=0;i<G->nm;i++){
		struct fhk_model *m = &G->models[i];
		for(size_t j=0;j<m->n_param;j++)  checku(m->params[j].map);
		for(size_t j=0;j<m->n_return;j++) checku(m->returns[j].map);
		for(size_t j=0;j<m->n_check;j++)  checku(m->checks[j].edge.map);
	}
#undef checku

	G->nu = maxu+1;
}
