#include "fhk.h"
#include "exec.h"
#include "arena.h"
#include "world.h"
#include "update.h"
#include "lex.h"
#include "bitmap.h"
#include "def.h"

#include <stddef.h>
#include <stdlib.h>
#include <string.h>

#define USET_ENVID (~0)

enum {
	V_VAR  = 1,
	V_ENV  = 2,
	V_COMP = 3,
	V_GLOB = 4
};

enum {
	U_OBJ  = 1
};

#define vname(v) ((struct xheader *) (v))->name
#define vtype(v) ((struct xheader *) (v))->type

struct xheader {
	const char *name;
	int type;
};

struct u_var {
	struct xheader header;
	struct fhk_var *x;
	lexid varid;
};

struct u_obj {
	const char *name;
	struct u_var *vars;
	w_obj *wobj;
};

struct u_env {
	struct xheader header;
	struct fhk_var *x;
	w_env *wenv;
};

struct u_comp {
	struct xheader header;
};

struct u_model {
	const char *name;
	ex_func *f;
};

struct ugraph {
	arena *arena;
	struct fhk_graph *G;
	struct xheader **xs;
};

struct uset_header {
	int type;

	bm8 *init_v;
	bm8 *reset_v, *reset_m;

	// often we are interested in the chosen model chains, so they can be logged/etc.
	// with this hook
	u_solver_cb solver_cb;
	void *solver_cb_udata;
};

struct uset_obj {
	struct uset_header header;
	struct u_obj *obj;
	world *world;
	// TODO: accept multiple objrefs here for "hierarchical" updating
	w_objref ref;
	size_t nv;
	struct u_var *vars[];
};

static void s_init(struct ugraph *u, struct uset_header *s, int type);
static void s_destroy(struct uset_header *s);
static void s_init_G(struct uset_header *s, struct fhk_graph *G);
static void s_reset_G(struct uset_header *s, struct fhk_graph *G);
static void s_cb_G(struct uset_header *s, struct fhk_graph *G, size_t nv, struct fhk_var **xs);

static void s_obj_compute_init(struct ugraph *u, struct uset_obj *s);
static void s_obj_compute_reset(struct ugraph *u, struct uset_obj *s);
static void s_obj_update_vec(struct ugraph *u, struct uset_obj *s, w_objvec *v);
#define obj_nv(o) ((o)->wobj->vtemplate->n_bands)

static pvalue v_resolve_var(struct uset_obj *s, struct u_var *var);
static pvalue v_resolve_env(struct uset_header *s, struct u_env *env);

static int G_model_exec(struct fhk_graph *G, void *udata, pvalue *ret, pvalue *args);
static int G_resolve_virtual(struct fhk_graph *G, void *udata, pvalue *value);
static const char *G_ddv(void *udata);
static const char *G_ddm(void *udata);

struct ugraph *u_create(struct fhk_graph *G){
	arena *arena = arena_create(1024);
	struct ugraph *u = arena_malloc(arena, sizeof(*u));
	u->arena = arena;

	u->xs = arena_malloc(arena, sizeof(*u->xs)*G->n_var);
	memset(u->xs, 0, sizeof(*u->xs)*G->n_var);

	u->G = G;
	G->model_exec = G_model_exec;
	G->resolve_virtual = G_resolve_virtual;
	G->debug_desc_var = G_ddv;
	G->debug_desc_model = G_ddm;

	return u;
}

void u_destroy(struct ugraph *u){
	arena_destroy(u->arena);
}

struct u_obj *u_add_obj(struct ugraph *u, w_obj *obj, const char *name){
	struct u_obj *ret = arena_malloc(u->arena, sizeof(*ret));
	ret->wobj = obj;
	size_t vsize = sizeof(*ret->vars) * obj_nv(ret);
	ret->vars = arena_malloc(u->arena, vsize);
	memset(ret->vars, 0, vsize);
	ret->name = arena_strcpy(u->arena, name);
	return ret;
}

struct u_var *u_add_var(struct ugraph *u, struct u_obj *obj, lexid varid, struct fhk_var *x,
		const char *name){

	struct u_var *var = &obj->vars[varid];
	vname(var) = arena_asprintf(u->arena, "%s:%s", obj->name, name);
	vtype(var) = V_VAR;
	var->varid = varid;
	var->x = x;
	x->udata = var;
	x->is_virtual = 1;
	u->xs[x->idx] = (struct xheader *) var;
	dv("fhk var[%d] = var %p %s [lexid=%d]\n", x->idx, var, vname(var), varid);
	return var;
}

struct u_env *u_add_env(struct ugraph *u, w_env *env, struct fhk_var *x, const char *name){
	struct u_env *ret = arena_malloc(u->arena, sizeof(*ret));
	vname(ret) = arena_strcpy(u->arena, name);
	vtype(ret) = V_ENV;
	ret->x = x;
	ret->wenv = env;
	x->udata = ret;
	x->is_virtual = 1;
	u->xs[x->idx] = (struct xheader *) ret;
	dv("fhk var[%d] = env %p %s\n", x->idx, ret, name);
	return ret;
}

struct u_comp *u_add_comp(struct ugraph *u, struct fhk_var *x, const char *name){
	struct u_comp *ret = arena_malloc(u->arena, sizeof(*ret));
	vname(ret) = arena_strcpy(u->arena, name);
	vtype(ret) = V_COMP;
	x->udata = ret;
	x->is_virtual = 0;
	u->xs[x->idx] = (struct xheader *) ret;
	dv("fhk var[%d] = computed %p %s\n", x->idx, ret, name);
	return ret;
}

struct u_model *u_add_model(struct ugraph *u, ex_func *f, struct fhk_model *m, const char *name){
	struct u_model *ret = arena_malloc(u->arena, sizeof(*ret));
	vname(ret) = arena_strcpy(u->arena, name);
	ret->f = f;
	m->udata = ret;
	dv("fhk model[%d] = ex %p %s [f=%p]\n", m->idx, ret, name, f);
	return ret;
}

struct uset_obj *uset_create_obj(struct ugraph *u, struct u_obj *obj, world *world, size_t nv,
		lexid *varids){

	struct uset_obj *s = malloc(sizeof(*s) + nv*sizeof(*s->vars));
	s_init(u, &s->header, U_OBJ);
	s->world = world;
	s->nv = nv;
	s->obj = obj;
	for(size_t i=0;i<nv;i++)
		s->vars[i] = &obj->vars[varids[i]];
	s_obj_compute_init(u, s);
	s_obj_compute_reset(u, s);
	return s;
}

void uset_update_obj(struct ugraph *u, struct uset_obj *s){
	w_obj *obj = s->obj->wobj;
	struct grid *g = &obj->grid;
	w_objvec **data = g->data;
	gridpos max = grid_max(g->order);

	for(gridpos i=0;i<max;i++){
		if(data[i])
			s_obj_update_vec(u, s, data[i]);
	}
}

void uset_destroy_obj(struct uset_obj *s){
	s_destroy(&s->header);
	free(s);
}

void uset_init_flag(struct uset_header *s, int xidx, fhk_vbmap flag){
	s->init_v[xidx] = flag.u8;
}

void uset_solver_cb(struct uset_header *s, u_solver_cb cb, void *udata){
	s->solver_cb = cb;
	s->solver_cb_udata = udata;
}

static void s_init(struct ugraph *u, struct uset_header *s, int type){
	s->init_v = bm_alloc(u->G->n_var);
	s->reset_v = bm_alloc(u->G->n_var);
	s->reset_m = bm_alloc(u->G->n_mod);
	s->solver_cb = NULL;
	s->type = type;
}

static void s_destroy(struct uset_header *s){
	free(s->init_v);
	free(s->reset_v);
	free(s->reset_m);
}

static void s_init_G(struct uset_header *s, struct fhk_graph *G){
	bm_copy((bm8 *) G->v_bitmaps, s->init_v, G->n_var);
	bm_zero((bm8 *) G->m_bitmaps, G->n_mod);
}

static void s_reset_G(struct uset_header *s, struct fhk_graph *G){
	bm_and2((bm8 *) G->v_bitmaps, s->reset_v, G->n_var);
	bm_and2((bm8 *) G->m_bitmaps, s->reset_m, G->n_mod);
}

static void s_cb_G(struct uset_header *s, struct fhk_graph *G, size_t nv, struct fhk_var **xs){
	if(s->solver_cb)
		s->solver_cb(s->solver_cb_udata, G, nv, xs);
}

static void s_obj_compute_init(struct ugraph *u, struct uset_obj *s){
	size_t nv = u->G->n_var;
	bm8 *init_v = s->header.init_v;
	bm_zero(init_v, nv);

	// envs are always given
	fhk_vbmap given = { .given=1 };
	for(size_t i=0;i<nv;i++){
		if(u->xs[i] && vtype(u->xs[i]) == V_ENV)
			init_v[i] = given.u8;
	}

	// first set all vars on the object to given
	for(size_t i=0;i<obj_nv(s->obj);i++){
		struct u_var *v = &s->obj->vars[i];
		if(v->x)
			init_v[v->x->idx] = given.u8;
	}

	// then set the requested ones to solve
	fhk_vbmap solve = { .solve=1 };
	for(size_t i=0;i<s->nv;i++){
		struct u_var *v = s->vars[i];
		init_v[v->x->idx] = solve.u8;
	}
}

static void s_obj_compute_reset(struct ugraph *u, struct uset_obj *s){
	size_t nv = u->G->n_var;
	size_t nm = u->G->n_mod;

	bm8 *reset_v = s->header.reset_v;
	bm8 *reset_m = s->header.reset_m;

	bm_zero(reset_v, nv);
	bm_zero(reset_m, nm);

	// each iteration the following is reset:
	// (1) all object variables
	// (2) envs with a smaller grid than the object grid
	// (3) everything depending on (1) & (2), above the requested vars
	
	// (1)
	for(size_t i=0;i<obj_nv(s->obj);i++){
		struct u_var *v = &s->obj->vars[i];
		if(v->x)
			reset_v[v->x->idx] = 0xff;
	}

	// (2)
	size_t order = s->obj->wobj->grid.order;
	for(size_t i=0;i<nv;i++){
		if(u->xs[i] && vtype(u->xs[i]) == V_ENV){
			struct u_env *e = (struct u_env *) u->xs[i];
			if(w_env_orderz(e->wenv) > order)
				reset_v[i] = 0xff;
		}
	}

	// (3)
	// zero the relevant indices first, fhk_inv_supp will set them
	for(size_t i=0;i<s->nv;i++){
		struct u_var *v = s->vars[i];
		reset_v[v->x->idx] = 0;
	}
	for(size_t i=0;i<s->nv;i++){
		struct u_var *v = s->vars[i];
		fhk_inv_supp(u->G, reset_v, reset_m, v->x);
	}

	// now each thing to reset is marked with 0xff, but we want to mask them out so negate them
	bm_not(reset_v, nv);
	bm_not(reset_m, nm);

	// finally, don't mask out given and solve bits
	fhk_vbmap keep = { .given=1, .solve=1 };
	bm_or(reset_v, nv, keep.u8);
}

static void s_obj_update_vec(struct ugraph *u, struct uset_obj *s, w_objvec *v){
	if(!v->n_used)
		return;

	// totally reset graph, this also sets the correct given/solve flags
	struct fhk_graph *G = u->G;
	s_init_G(&s->header, G);
	G->udata = s;
	s->ref.vec = v;

	// collect new vectors to put the results in, this is done for 2 reasons
	//   - since we just change the pointer, the old data doesn't need to be copied to safety
	//   - we avoid overwriting old data since that could in theory change the results of some models
	// also collect the corresponding fhk var pointers here
	size_t nv = s->nv;
	w_vband bands[nv];
	struct fhk_var *xs[nv];
	for(size_t i=0;i<nv;i++){
		struct u_var *var = s->vars[i];
		lexid varid = var->varid;
		bands[i].type = v->bands[varid].type;
		bands[i].stride_bits = v->bands[varid].stride_bits;
		bands[i].data = w_alloc_band(s->world, v, varid);
		xs[i] = var->x;
	}

	// solve!
	size_t n = v->n_used;
	for(size_t i=0;i<n;i++){
		s_reset_G(&s->header, G);
		s->ref.idx = i;

		for(size_t j=0;j<nv;j++){
			int res = fhk_solve(G, xs[j]);
			assert(!res); // TODO error handling goes here
		}

		for(size_t j=0;j<nv;j++){
			tvalue v = vdemote(xs[j]->mark.value, bands[j].type);
			w_vb_vcopy(&bands[j], i, v);
		}

		s_cb_G(&s->header, G, nv, xs);
	}

	// (5) replace only the changed pointers, the old data is safe generally in the previous
	// branch arena
	for(size_t i=0;i<nv;i++)
		w_obj_swap(s->world, v, s->vars[i]->varid, bands[i].data);
}

static pvalue v_resolve_var(struct uset_obj *s, struct u_var *var){
	type t = s->ref.vec->bands[var->varid].type;
	return vpromote(w_obj_read1(&s->ref, var->varid), t);
}

static pvalue v_resolve_env(struct uset_header *s, struct u_env *env){
	if(s->type == U_OBJ){
		struct uset_obj *o = (struct uset_obj *) s;
		gridpos pos = w_obj_read1(&o->ref, VARID_POSITION).z;
		return vpromote(w_env_readpos(env->wenv, pos), env->wenv->type);
	}

	UNREACHABLE();
}

static int G_model_exec(struct fhk_graph *G, void *udata, pvalue *ret, pvalue *args){
	(void)G;

	struct u_model *m = udata;
	return ex_exec(m->f, ret, args);
}

static int G_resolve_virtual(struct fhk_graph *G, void *udata, pvalue *value){
	switch(vtype(udata)){
		case V_VAR: *value = v_resolve_var(G->udata, udata); break;
		case V_ENV: *value = v_resolve_env(G->udata, udata); break;
		default: UNREACHABLE();
	}

	return FHK_OK;
}

static const char *G_ddv(void *udata){
	return vname(udata);
}

static const char *G_ddm(void *udata){
	return ((struct u_model *) udata)->name;
}
