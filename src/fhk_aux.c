#include "fhk.h"
#include "arena.h"
#include "bitmap.h"

#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#include <assert.h>

static void init_vars(struct fhk_var *x, size_t n);
static void init_models(struct fhk_model *m, size_t n);

struct fhk_graph *fhk_alloc_graph(arena *arena, size_t n_var, size_t n_mod){
	struct fhk_graph *G = arena_malloc(arena, sizeof(*G));
	memset(G, 0, sizeof(*G));
	G->n_var = n_var;
	G->n_mod = n_mod;
	G->vars = arena_malloc(arena, sizeof(*G->vars) * n_var);
	G->models = arena_malloc(arena, sizeof(*G->models) * n_mod);
	memset(G->vars, 0, sizeof(*G->vars) * n_var);
	memset(G->models, 0, sizeof(*G->models) * n_mod);
	init_vars(G->vars, n_var);
	init_models(G->models, n_mod);
	G->v_bitmaps = arena_alloc(arena, BITMAP_SIZE(n_var), BITMAP_ALIGN);
	G->m_bitmaps = arena_alloc(arena, BITMAP_SIZE(n_mod), BITMAP_ALIGN);
	return G;
}

void fhk_alloc_checks(arena *arena, struct fhk_model *m, size_t n_check, struct fhk_check *checks){
	m->n_check = n_check;
	if(!n_check)
		return;

	m->checks = arena_malloc(arena, n_check * sizeof(*checks));
	memcpy(m->checks, checks, n_check * sizeof(*checks));
}

void fhk_alloc_params(arena *arena, struct fhk_model *m, size_t n_param, struct fhk_var **params){
	m->n_param = n_param;
	if(!n_param)
		return;

	m->params = arena_malloc(arena, n_param * sizeof(*params));
	memcpy(m->params, params, n_param * sizeof(*params));
}

void fhk_alloc_returns(arena *arena, struct fhk_model *m, size_t n_ret){
	assert(n_ret > 0);
	m->returns = arena_malloc(arena, n_ret * sizeof(*m->returns));
}

void fhk_alloc_models(arena *arena, struct fhk_var *x, size_t n_mod, struct fhk_model **models){
	x->n_mod = n_mod;
	if(!n_mod)
		return;

	x->models = arena_malloc(arena, n_mod * sizeof(*models));
	x->mret = arena_malloc(arena, n_mod * sizeof(*x->mret));
	memcpy(x->models, models, n_mod * sizeof(*models));
}

void fhk_link_ret(struct fhk_model *m, struct fhk_var *x, size_t mind, size_t xind){
	assert(xind < x->n_mod);
	x->mret[xind] = &m->returns[mind];
}

struct fhk_var *fhk_get_var(struct fhk_graph *G, unsigned idx){
	assert(idx < G->n_var);
	return &G->vars[idx];
}

struct fhk_model *fhk_get_model(struct fhk_graph *G, unsigned idx){
	assert(idx < G->n_mod);
	return &G->models[idx];
}

struct fhk_model *fhk_get_select(struct fhk_var *x){
	return x->models[x->select_model];
}

static void init_vars(struct fhk_var *x, size_t n){
	for(size_t i=0;i<n;i++){
		x[i].idx = i;
	}
}

static void init_models(struct fhk_model *m, size_t n){
	for(size_t i=0;i<n;i++){
		m[i].idx = i;
	}
}
