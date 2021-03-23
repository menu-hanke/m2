#include "fhk.h"
#include "def.h"

#include "../def.h"

#include <stdlib.h>
#include <stdint.h>
#include <stdalign.h>
#include <stdbool.h>
#include <string.h>
#include <math.h>
#include <assert.h>

#define OIDX(o)         ((fhk_idx)((o)&0xffff))
#define OTAG(tag)       ((fhk_obj)(tag)<<60)
#define EXTMAP(map)     ((int8_t)((map)&0xff))
#define EXTINVERSE(map) ((int8_t)(((map)>>8)&0xff))

typedef struct {
	struct { uint32_t pos; uint32_t alloc; } header[0];
	uint8_t data[0];
} __attribute__((may_alias)) vec;

#define vec_header(v)  (((vec*)(v))->header[-1])
#define vec_destroy(v) free(&vec_header(v))
#define vec_num(v)     ((v) ? (int64_t)(vec_header(v).pos/sizeof(*v)) : 0)
#define vec_add(v)     (vec_alloc((vec**)v,sizeof(**v)) ? (vec_num(*v)-1) : (-1))

struct def_edge {
	fhk_idx idx;
	fhk_extmap map;
};

struct def_shedge {
	fhk_idx idx;
	fhk_extmap map;
	float penalty;
};

struct def_model {
	struct def_edge *params;
	struct def_edge *returns;
	struct def_shedge *shadows;
	fhk_grp group;
	float k, c;
	float cmin;
};

struct def_var {
	fhk_grp group;
	uint16_t size;

	// these don't strictly need to be counted here, but this way we can return
	// an error instantly when max edge count is exceeded, and then assume everything is
	// ok in the graph builder, which simplifies the building process a bit.
	// this also lets us skip a counting step.
	uint16_t n_fwd;
	uint8_t n_mod;
	float cdiff;
};

struct def_shadow {
	fhk_shvalue arg;
	fhk_idx xi;
	uint8_t guard;
};

struct fhk_def {
	struct def_model *models;
	struct def_var *vars;
	struct def_shadow *shadows;

	// need to maintain this for umap indexing
	int32_t maxg;

	// nonconstant umap -> group association
	int32_t minimap, maxkmap;
	fhk_grp umap_assoc[-G_MINUMAP];
};

static bool d_checkmap(struct fhk_def *D, fhk_extmap map, xgrp from, xgrp to);

static void g_copy_nodes(struct fhk_graph *G, struct fhk_def *D);
static void *g_build_edges(struct fhk_graph *G, struct fhk_def *D, void *p);
static void *g_copy_umaps(struct fhk_graph *G, struct fhk_def *D, void *p);
static fhk_map g_extmap(struct fhk_graph *G, xidx xi, fhk_extmap emap);
static fhk_map g_extmapi(struct fhk_graph *G, xidx mi, fhk_extmap emap);
static bool g_mretbuf(struct fhk_graph *G, xidx mi);
static void g_mflags(struct fhk_graph *G);
static void g_reorder_edges(struct fhk_graph *G, struct fhk_def *D);

static void *vec_alloc(vec **v, uint32_t num);

struct fhk_def *fhk_create_def(){
	struct fhk_def *D = malloc(sizeof(*D));

	D->models = NULL;
	D->vars = NULL;
	D->shadows = NULL;

	D->maxg = -1;
	D->minimap = 0;
	D->maxkmap = -1;
	
	for(int32_t i=0;i<-G_MINUMAP;i++)
		D->umap_assoc[i] = FHK_NGRP;

	return D;
}

void fhk_destroy_def(struct fhk_def *D){
	for(xidx i=0;i<vec_num(D->models);i++){
		struct def_model *dm = &D->models[i];
		if(dm->params)  vec_destroy(dm->params);
		if(dm->returns) vec_destroy(dm->returns);
		if(dm->shadows) vec_destroy(dm->shadows);
	}

	if(D->models)  vec_destroy(D->models);
	if(D->vars)    vec_destroy(D->vars);
	if(D->shadows) vec_destroy(D->shadows);

	free(D);
}

// keep in sync with fhk_build_graph!
size_t fhk_graph_size(struct fhk_def *D){
	size_t ne = 0, nc = 0;

	for(xidx i=0;i<vec_num(D->models);i++){
		struct def_model *dm = &D->models[i];
		ne += 2 * (vec_num(dm->params) + vec_num(dm->returns));
		nc += vec_num(dm->shadows);
	}

	return sizeof(struct fhk_graph)
		+ vec_num(D->models) * sizeof(struct fhk_model)
		+ (vec_num(D->vars) + vec_num(D->shadows)) * sizeof(struct fhk_var)
		+ nc * sizeof(fhk_shedge)
		+ ne * sizeof(fhk_edge)
		+ (-D->minimap) * sizeof(fhk_grp);
}

fhk_idx fhk_graph_idx(struct fhk_def *D, fhk_obj o){
	switch(FHKO_TAG(o)){
		case FHKO_MODEL:  return ~OIDX(o);
		case FHKO_VAR:    return OIDX(o);
		case FHKO_SHADOW: return vec_num(D->vars) + OIDX(o);
		default:          return FHK_NIDX;
	}
}

struct fhk_graph *fhk_build_graph(struct fhk_def *D, void *p){
	static_assert(alignof(struct fhk_graph) == alignof(struct fhk_model));
	static_assert(alignof(struct fhk_graph) == alignof(struct fhk_var));
	static_assert(sizeof(struct fhk_shadow) == sizeof(struct fhk_var));
	static_assert(alignof(struct fhk_graph) >= alignof(fhk_shedge));
	static_assert(alignof(fhk_shedge) >= alignof(fhk_edge));
	static_assert(alignof(fhk_edge) >= alignof(fhk_grp));

	if(!p)
		p = malloc(fhk_graph_size(D));

#if FHK_DEBUG
	void *_mem = p;
#endif

	assert(p == ALIGN(p, alignof(struct fhk_graph)));

	p += vec_num(D->models) * sizeof(struct fhk_model);
	struct fhk_graph *G = p;
	p += sizeof(struct fhk_graph);
	p += (vec_num(D->vars) + vec_num(D->shadows)) * sizeof(struct fhk_var);

	g_copy_nodes(G, D);
	p = g_build_edges(G, D, p);
	p = g_copy_umaps(G, D, p);
	g_reorder_edges(G, D);
	g_mflags(G);

#if FHK_DEBUG
	assert(p == _mem+fhk_graph_size(D));
#endif

	return G;
}

// only use on malloc'd graphs produced by fhk_build_graph
void fhk_destroy_graph(struct fhk_graph *G){
	free(G->models - G->nm);
}

fhk_obj fhk_def_add_model(struct fhk_def *D, fhk_grp group, float k, float c, float cmin){
	if(vec_num(D->models) == G_MAXIDX)
		return FHKE_INVAL | E_META(1, I, G_MAXIDX);

	if(group + D->maxkmap > G_MAXUMAP)
		return FHKE_INVAL | E_META(1, G, group);

	if(k < 0 || c < 1)
		return FHKE_INVAL;

	xidx idx = vec_add(&D->models);
	if(idx < 0)
		return FHKE_MEM;

	D->maxg = max(D->maxg, (int32_t)group);

	struct def_model *dm = &D->models[idx];
	dm->params = NULL;
	dm->returns = NULL;
	dm->shadows = NULL;
	dm->group = group;
	dm->k = k;
	dm->c = c;
	dm->cmin = cmin;

	return OTAG(FHKO_MODEL) | idx;
}

fhk_obj fhk_def_add_var(struct fhk_def *D, fhk_grp group, uint16_t size, float cdiff){
	if(vec_num(D->vars)+vec_num(D->shadows) == G_MAXIDX)
		return FHKE_INVAL | E_META(1, I, G_MAXIDX);

	if(group + D->maxkmap > G_MAXUMAP)
		return FHKE_INVAL | E_META(1, G, group);

	// solver uses size as an alignment, so it must be a power of 2.
	// note: if this causes problems, it can be easily changed by adding a separate alignment
	// variable (or just aligning to 16 always, like malloc)
	if(size & (size-1))
		return FHKE_INVAL;

	xidx idx = vec_add(&D->vars);
	if(idx < 0)
		return FHKE_MEM;

	D->maxg = max(D->maxg, (int32_t)group);

	struct def_var *dv = &D->vars[idx];
	dv->group = group;
	dv->size = size;
	dv->n_fwd = 0;
	dv->n_mod = 0;
	dv->cdiff = cdiff;

	return OTAG(FHKO_VAR) | idx;
}

fhk_obj fhk_def_add_shadow(struct fhk_def *D, fhk_obj var, uint8_t guard, fhk_shvalue arg){
	if(vec_num(D->vars)+vec_num(D->shadows) == G_MAXIDX)
		return FHKE_INVAL | E_META(1, I, G_MAXIDX);

	if(FHKO_TAG(var) != FHKO_VAR)
		return FHKE_INVAL;

	xidx xi = OIDX(var);
	if((uint16_t)xi > vec_num(D->vars))
		return FHKE_INVAL | E_META(1, I, xi);

	xidx idx = vec_add(&D->shadows);
	if(idx < 0)
		return FHKE_MEM;

	struct def_shadow *ds = &D->shadows[idx];
	ds->xi = xi;
	ds->guard = guard;
	ds->arg = arg;

	return OTAG(FHKO_SHADOW) | idx;
}

fhk_ei fhk_def_add_param(struct fhk_def *D, fhk_obj model, fhk_obj var, fhk_extmap map){
	if(FHKO_TAG(model) != FHKO_MODEL || FHKO_TAG(var) != FHKO_VAR)
		return FHKE_INVAL;

	xidx mi = OIDX(model);
	xidx xi = OIDX(var); 

	if((uint16_t)mi > vec_num(D->models))
		return FHKE_INVAL | E_META(1, I, mi);

	if((uint16_t)xi > vec_num(D->vars))
		return FHKE_INVAL | E_META(1, I, xi);

	struct def_model *dm = &D->models[mi];
	struct def_var *dx = &D->vars[xi];

	if(vec_num(dm->params) == G_MAXEDGE || dx->n_fwd == G_MAXFWDE)
		return FHKE_INVAL;

	if(!d_checkmap(D, map, dm->group, dx->group))
		return FHKE_INVAL;

	fhk_idx idx = vec_add(&dm->params);
	if(idx < 0)
		return FHKE_MEM;

	dx->n_fwd++;

	struct def_edge *e = &dm->params[idx];
	e->idx = xi;
	e->map = map;

	return 0;
}

fhk_ei fhk_def_add_return(struct fhk_def *D, fhk_obj model, fhk_obj var, fhk_extmap map){
	if(FHKO_TAG(model) != FHKO_MODEL || FHKO_TAG(var) != FHKO_VAR)
		return FHKE_INVAL;

	xidx mi = OIDX(model);
	xidx xi = OIDX(var); 

	if((uint16_t)mi > vec_num(D->models))
		return FHKE_INVAL | E_META(1, I, mi);

	if((uint16_t)xi > vec_num(D->vars))
		return FHKE_INVAL | E_META(1, I, xi);

	struct def_model *dm = &D->models[mi];
	struct def_var *dx = &D->vars[xi];

	if(vec_num(dm->returns) == G_MAXEDGE || dx->n_mod == G_MAXMODE)
		return FHKE_INVAL;

	if(!d_checkmap(D, map, dm->group, dx->group))
		return FHKE_INVAL;

	fhk_idx idx = vec_add(&dm->returns);
	if(idx < 0)
		return FHKE_MEM;

	dx->n_mod++;

	struct def_edge *e = &dm->returns[idx];
	e->idx = xi;
	e->map = map;

	return 0;
}

fhk_ei fhk_def_add_check(struct fhk_def *D, fhk_obj model, fhk_obj shadow, fhk_extmap map,
		float penalty){

	if(FHKO_TAG(model) != FHKO_MODEL || FHKO_TAG(shadow) != FHKO_SHADOW)
		return FHKE_INVAL;

	xidx mi = OIDX(model);
	xidx wi = OIDX(shadow);

	if((uint16_t)mi > vec_num(D->models))
		return FHKE_INVAL | E_META(1, I, mi);

	if((uint16_t)wi > vec_num(D->shadows))
		return FHKE_INVAL | E_META(1, I, wi);

	struct def_model *dm = &D->models[mi];

	if(vec_num(dm->shadows) == G_MAXEDGE)
		return FHKE_INVAL;

	if(!d_checkmap(D, map, dm->group, D->vars[D->shadows[wi].xi].group))
		return FHKE_INVAL;

	fhk_idx idx = vec_add(&dm->shadows);
	if(idx < 0)
		return FHKE_MEM;

	struct def_shedge *e = &dm->shadows[idx];
	e->idx = wi;
	e->map = map;
	e->penalty = penalty;

	return 0;
}

static bool d_checkmap(struct fhk_def *D, fhk_extmap map, xgrp from, xgrp to){
	// ident: between groups is allowed, use at your own risk.
	// space: always allowed.
	if(map >= FHKMAP_IDENT)
		return true;

	xmap m = EXTMAP(map);
	xmap i = EXTINVERSE(map);

	// note: even if the add fails for some reason after this (eg. out of memory),
	// the map will still be associated with the group.

	if(MAP_ISNONCONST(m)){
		if(D->umap_assoc[m - G_MINUMAP] == FHK_NGRP) D->umap_assoc[m - G_MINUMAP] = from;
		else if(D->umap_assoc[m - G_MINUMAP] != from) return false;
	}

	if(MAP_ISNONCONST(i)){
		if(D->umap_assoc[i - G_MINUMAP] == FHK_NGRP) D->umap_assoc[i - G_MINUMAP] = to;
		else if(D->umap_assoc[i - G_MINUMAP] != to) return false;
	}

	// no need to check for constness, this works because kmap>=0 and imap<0
	xmap maxkmap = max(D->maxkmap, max(m, i));
	xmap minimap = min(D->minimap, min(m, i));

	if(D->maxg + maxkmap > G_MAXUMAP) return false;
	if(minimap < G_MINUMAP) return false;

	D->maxkmap = maxkmap;
	D->minimap = minimap;

	return true;
}

static void g_copy_nodes(struct fhk_graph *G, struct fhk_def *D){
	G->nv = vec_num(D->vars);
	G->nx = G->nv + vec_num(D->shadows);
	G->nm = vec_num(D->models);
	// if the graph is empty this will still set ng=1, but it doesn't matter
	G->ng = D->maxg + 1;
	G->nimap = -D->minimap;
	G->nkmap = G->ng + D->maxkmap + 1; // includes space mappings
#if FHK_DEBUG
	G->dsym = NULL;
#endif

	for(xidx i=0;i<G->nv;i++){
		struct def_var *dx = &D->vars[i];
		struct fhk_var *x = &G->vars[i];

		x->group = dx->group;
		x->size = dx->size;
		x->n_fwd = dx->n_fwd;
		x->n_mod = dx->n_mod;
	}

	for(xidx i=G->nv;i<G->nx;i++){
		struct def_shadow *ds = &D->shadows[i - G->nv];
		struct fhk_shadow *w = &G->shadows[i];

		w->arg = ds->arg;
		w->xi = ds->xi;
		w->group = G->vars[w->xi].group;
		w->guard = ds->guard;
	}

	for(xidx i=0;i<G->nm;i++){
		struct def_model *dm = &D->models[i];
		struct fhk_model *m = &G->models[~i];

		m->group = dm->group;
		m->k = dm->k;
		m->c = dm->c;
		m->cmin = dm->cmin;

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

static void *g_build_edges(struct fhk_graph *G, struct fhk_def *D, void *p){
	static_assert(offsetof(struct fhk_model, shadows) == offsetof(struct fhk_model, params));
	static_assert(alignof(fhk_edge) <= alignof(fhk_shedge));

	// alloc strategy:
	//     [v1 models] [v1_m1 backward edges] ... [v1_mN bw edges] [v2 models] ...
	//     [v1 fwds] [v1_f1 returns] [v1_f2 returns] ... [v1_fN returns] [v2 fwds] [v2_f1 returns] ...
	//
	// this will make it so that there is a good chance that the candidate model's checks/params will
	// be loaded into cache when the model list for a variable is walked.
	//
	// bw/fw edges are allocated separately because they are used by different parts of the solver.
	// (main solver uses bw edges, cyclic solver uses fw edges, model evaluation may use return
	// for complex models)
	
	// the allocation proceeds as follows: *p is guaranteed to have enough space, so we use it
	// as a scratch space to construct the v->m edges sequentially (m->v edges don't need to be
	// constructed, just counted). then we assign the edge pointers, but don't write any edges
	// yet (as *p is our scratch space). then after assigning all pointers, we can construct
	// the real edges. this way we avoid any extra allocations.

	// assign x-> edge pointers to the temp scratch space, we will construct them here first

	void *scratch = p;

	for(xidx i=0;i<G->nv;i++){
		struct fhk_var *x = &G->vars[i];
		x->models = scratch;
		scratch += x->n_mod * sizeof(*x->models);
		x->fwds = scratch;
		scratch += x->n_fwd * sizeof(*x->fwds);

		// these will be the running index counters in the next step
		x->n_mod = 0;
		x->n_fwd = 0;
	}

	// construct temp x-> edges (only indices, we don't need mapping yet)

	for(xidx i=0;i<G->nm;i++){
		struct def_model *dm = &D->models[i];

		for(int64_t j=0;j<vec_num(dm->params);j++){
			struct fhk_var *x = &G->vars[dm->params[j].idx];
			x->fwds[x->n_fwd++].idx = ~i;
		}

		for(int64_t j=0;j<vec_num(dm->returns);j++){
			struct fhk_var *x = &G->vars[dm->returns[j].idx];
			x->models[x->n_mod++].idx = ~i;
		}
	}

	// count m->x edge positions
	
	for(xidx i=0;i<G->nm;i++){
		struct def_model *dm = &D->models[i];
		struct fhk_model *m = &G->models[~i];

		m->params = NULL;
		m->returns = NULL;
		m->shadows = NULL;
		m->p_shadow = -vec_num(dm->shadows);
		m->p_cparam = 0;
		m->p_param = vec_num(dm->params);
		m->p_return = vec_num(dm->returns);

		for(int64_t j=0;j<vec_num(dm->params);j++){
			struct def_var *dx = &D->vars[dm->params[j].idx];
			if(dx->n_mod) m->p_cparam++;
		}
	}

	// assign backwards edge pointers

	for(xidx i=0;i<G->nv;i++){
		struct fhk_var *x = &G->vars[i];
		fhk_edge *models = x->models;
		x->models = p;
		p += x->n_mod * sizeof(*x->models);

		for(int64_t j=0;j<x->n_mod;j++){
			struct fhk_model *m = &G->models[models[j].idx];
			if(!m->params){
				if(m->p_shadow) p = ALIGN(p, alignof(*m->shadows));
				p += -m->p_shadow * sizeof(*m->shadows);
				m->params = p;
				p += m->p_param * sizeof(*m->params);
			}
		}

		x->n_mod = 0; // this will be a counter
	}

	// assign forward edge pointers

	for(xidx i=0;i<G->nv;i++){
		struct fhk_var *x = &G->vars[i];
		fhk_edge *fwds = x->fwds;
		x->fwds = p;
		p += x->n_fwd * sizeof(*x->fwds);

		for(int64_t j=0;j<x->n_fwd;j++){
			struct fhk_model *m = &G->models[fwds[j].idx];
			if(!m->returns){
				m->returns = p;
				p += m->p_return * sizeof(*m->returns);
			}
		}

		x->n_fwd = 0; // counter
	}

	// assign the rest. models with no incoming edges don't get assigned in the above loops.
	// however, all shadows will get assigned because each shadow is attached to a variable.

	for(xidx i=0;i<G->nm;i++){
		struct fhk_model *m = &G->models[~i];

		if(!m->params){
			if(m->p_shadow) p = ALIGN(p, alignof(*m->shadows));
			p += -m->p_shadow * sizeof(*m->shadows);
			m->params = p;
			p += m->p_param * sizeof(*m->params);
		}

		if(!m->returns){
			m->returns = p;
			p += m->p_return * sizeof(*m->returns);
		}
	}

	// now we can construct the real edges!

	for(xidx i=0;i<G->nm;i++){
		struct def_model *dm = &D->models[i];
		struct fhk_model *m = &G->models[~i];

		// shadows (m->w)
		{
			int64_t p_shadow = 0;

			for(int64_t j=0;j<vec_num(dm->shadows);j++){
				struct def_shedge *e = &dm->shadows[j];
				struct fhk_shadow *w = &G->shadows[G->nv + e->idx];
				struct def_var *dx = &D->vars[w->xi]; // use def_var because n_mod is zeroed in G

				fhk_shedge *ep = &m->shadows[--p_shadow];
				ep->penalty = e->penalty;
				ep->map = g_extmap(G, w->xi, e->map);
				ep->idx = G->nv + e->idx;
				ep->flags = dx->n_mod ? W_COMPUTED : 0;
			}
		}

		// params (m->v) & fwd (v->m)
		{
			int64_t p_cparam = 0;
			int64_t p_gparam = m->p_cparam;

			for(int64_t j=0;j<vec_num(dm->params);j++){
				struct def_edge *de = &dm->params[j];
				struct fhk_var *x = &G->vars[de->idx];
				struct def_var *dx = &D->vars[de->idx];

				fhk_edge *ep = &m->params[dx->n_mod ? (p_cparam++) : (p_gparam++)];
				ep->idx = de->idx;
				ep->ex = j;
				ep->map = g_extmap(G, de->idx, de->map);

				fhk_edge *ei = &x->fwds[x->n_fwd++];
				ei->idx = ~i;
				ei->map = g_extmapi(G, ~i, de->map);
			}
		}

		// returns (m->v) & models (v->m)
		for(int64_t j=0;j<vec_num(dm->returns);j++){
			struct def_edge *de = &dm->returns[j];
			struct fhk_var *x = &G->vars[de->idx];

			fhk_edge *ep = &m->returns[j];
			ep->idx = de->idx;
			ep->ex = j;
			ep->map = g_extmap(G, de->idx, de->map);

			fhk_edge *ei = &x->models[x->n_mod++];
			ei->idx = ~i;
			ei->ex = j;
			ei->map = g_extmapi(G, ~i, de->map);
		}
	}

	return p;
}

static fhk_map g_extmap(struct fhk_graph *G, xidx xi, fhk_extmap emap){
	switch(emap){
		case FHKMAP_IDENT: return MAP_IDENT;
		case FHKMAP_SPACE: return MAP_SPACE(G->vars[xi].group);
		default:           return MAP_UMAP(EXTMAP(emap), G->ng);
	}
}

static fhk_map g_extmapi(struct fhk_graph *G, xidx mi, fhk_extmap emap){
	switch(emap){
		case FHKMAP_IDENT: return MAP_IDENT;
		case FHKMAP_SPACE: return MAP_SPACE(G->models[mi].group);
		default:           return MAP_UMAP(EXTINVERSE(emap), G->ng);
	}
}

static void *g_copy_umaps(struct fhk_graph *G, struct fhk_def *D, void *p){
	intptr_t off = (-D->minimap)*sizeof(*D->umap_assoc);
	memcpy(p, D->umap_assoc + (D->minimap - G_MINUMAP), off);
	p += off;
	G->umap_assoc = p;
	return p;
}

static bool g_mretbuf(struct fhk_graph *G, xidx mi){
	// if the model being selected implies it will be always chosen for each return edge,
	// we can skip the the temp buffer and write directly to var memory.
	// some of these special cases are:
	//     (1) model returns only 1 variable and exactly 1 instance of that variable
	//     (2) model is the only model for each return variable AND the map is an interval
	//         NOTE: you could detect the interval-ness at runtime (TODO)
	
	struct fhk_model *m = &G->models[mi];

	// (1)
	if(m->p_return == 1 && m->returns[0].map == MAP_IDENT)
		return false;

	// (2)
	for(int64_t i=0;i<m->p_return;i++){
		struct fhk_var *x = &G->vars[m->returns[i].idx];
		if(x->n_mod != 1 || MAP_ISUSER(m->returns[i].map, G->ng))
			return true;
	}

	return false;
}

static void g_mflags(struct fhk_graph *G){
	for(int64_t i=0;i<G->nm;i++){
		struct fhk_model *m = &G->models[~i];
		m->flags = 0;

		if(!g_mretbuf(G, ~i))
			m->flags |= M_NORETBUF;
	}
}

static void g_reorder_edges(struct fhk_graph *G, struct fhk_def *D){
#define swap(a, b) do { typeof(a) _a = (a); (a) = (b); (b) = _a; } while(0)
	for(int64_t i=0;i<G->nm;i++){
		struct fhk_model *m = &G->models[~i];

		// sort computed params by cost difference (in reverse order, because
		// that's how the solver iterates them)
		for(int64_t j=0;j<m->p_cparam;j++){
			for(int64_t k=j+1;k<m->p_cparam;k++){
				if(D->vars[m->params[j].idx].cdiff > D->vars[m->params[k].idx].cdiff)
					swap(m->params[j], m->params[k]);
			}
			dv("%s -> %s (#%ld) delta: %g\n",
					fhk_dsym(G, ~i),
					fhk_dsym(G, m->params[j].idx),
					j, D->vars[m->params[j].idx].cdiff);
		}


		// and shadows by penalty
		for(int64_t j=m->p_shadow;j;j++){
			for(int64_t k=j+1;k;k++){
				if(m->shadows[j].penalty < m->shadows[k].penalty)
					swap(m->shadows[j], m->shadows[k]);
			}
			dv("%s => %s (#%ld) penalty: %g\n",
					fhk_dsym(G, ~i),
					fhk_dsym(G, m->shadows[j].idx),
					j, m->shadows[j].penalty);
		}
	}
#undef swap
}

static void *vec_alloc(vec **v, uint32_t num){
	void *p;
	uint32_t alloc, pos;

	if(*v){
		p = &vec_header(*v);
		alloc = vec_header(*v).alloc;
		pos = vec_header(*v).pos;
	}else{
		p = NULL;
		alloc = 0;
		pos = 0;
	}

	if(pos+num > alloc){
		do {
			alloc = alloc ? (2*alloc) : 64;
		} while(pos+num > alloc);

		p = realloc(p, alloc + sizeof(vec_header(*v)));
		if(!p)
			return NULL;

		*v = p + sizeof(vec_header(*v));
		vec_header(*v).alloc = alloc;
	}

	vec_header(*v).pos = pos+num;
	return (*v)->data + pos;
}
