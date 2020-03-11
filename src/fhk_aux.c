#include "fhk.h"
#include "arena.h"
#include "bitmap.h"
#include "type.h"

#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#include <assert.h>

#define COPY_ARENA(a, ndest, nsrc, dest, src)\
	do {\
		(ndest) = (nsrc);\
		if((nsrc)){\
			(dest) = arena_malloc(a, (nsrc) * sizeof(*(src)));\
			memcpy((dest), (src), (nsrc) * sizeof(*(src)));\
		}\
	} while(0)

struct fhk_graph *fhk_alloc_graph(arena *arena, size_t n_var, size_t n_mod){
	struct fhk_graph *G = arena_malloc(arena, sizeof(*G));
	memset(G, 0, sizeof(*G));
	G->n_var = n_var;
	G->n_mod = n_mod;
	G->vars = arena_malloc(arena, sizeof(*G->vars) * n_var);
	G->models = arena_malloc(arena, sizeof(*G->models) * n_mod);
	memset(G->vars, 0, sizeof(*G->vars) * n_var);
	memset(G->models, 0, sizeof(*G->models) * n_mod);
	G->v_bitmaps = arena_alloc(arena, BITMAP_SIZE(n_var), BITMAP_ALIGN);
	G->m_bitmaps = arena_alloc(arena, BITMAP_SIZE(n_mod), BITMAP_ALIGN);
	fhk_graph_init(G);
	return G;
}

void fhk_copy_checks(arena *arena, struct fhk_model *m, size_t n_check, struct fhk_check *checks){
	COPY_ARENA(arena, m->n_check, n_check, m->checks, checks);
}

void fhk_copy_params(arena *arena, struct fhk_model *m, size_t n_param, struct fhk_var **params){
	COPY_ARENA(arena, m->n_param, n_param, m->params, params);
}

void fhk_copy_returns(arena *arena, struct fhk_model *m, size_t n_ret, struct fhk_var **returns){
	COPY_ARENA(arena, m->n_return, n_ret, m->returns, returns);

	if(n_ret)
		m->rvals = arena_malloc(arena, n_ret * sizeof(*m->rvals));
}

void fhk_compute_links(arena *arena, struct fhk_graph *G){
	// (1) init for counting
	for(unsigned i=0;i<G->n_var;i++){
		struct fhk_var *x = &G->vars[i];

		x->n_mod = 0;
		x->n_fwd = 0;
	}

	// (2) count links for allocating
	for(unsigned i=0;i<G->n_mod;i++){
		struct fhk_model *m = &G->models[i];

		for(unsigned j=0;j<m->n_return;j++)
			m->returns[j]->n_mod++;

		for(unsigned j=0;j<m->n_param;j++)
			m->params[j]->n_fwd++;
	}

	// (3) allocate links
	for(unsigned i=0;i<G->n_var;i++){
		struct fhk_var *x = &G->vars[i];

		if(x->n_mod){
			x->models = arena_malloc(arena, x->n_mod * sizeof(*x->models));
			x->n_mod = 0;
		}

		if(x->n_fwd){
			x->fwd_models = arena_malloc(arena, x->n_fwd * sizeof(*x->fwd_models));
			x->n_fwd = 0;
		}
	}

	// (4) record links
	for(unsigned i=0;i<G->n_mod;i++){
		struct fhk_model *m = &G->models[i];

		for(unsigned j=0;j<m->n_return;j++){
			struct fhk_var *x = m->returns[j];
			x->models[x->n_mod] = m;
			x->n_mod++;
		}

		for(unsigned j=0;j<m->n_param;j++){
			struct fhk_var *x = m->params[j];
			x->fwd_models[x->n_fwd++] = m;
		}
	}
}
