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

#define VM_GIVEN ((fhk_vbmap) {.given=1}).u8
#define VM_SOLVE ((fhk_vbmap) {.solve=1}).u8

enum {
	V_VAR  = 1,
	V_ENV  = 2,
	V_COMP = 3,
	V_GLOB = 4
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
	struct u_obj *obj;
	lexid varid;
};

struct u_obj {
	const char *name;
	struct u_var *vars;
	w_obj *wobj;
	w_objref bind;
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
	gridpos update_pos;
};

#define obj_nv(o) ((o)->wobj->vtemplate.n_bands)
#define u_nv(u)   ((u)->G->n_var)

static void mark_obj(bm8 *mark_v, struct u_obj *obj, uint8_t mark);
static void mark_envs(bm8 *mark_v, struct ugraph *u, uint8_t mark);
static void mark_envs_z(bm8 *mark_v, struct ugraph *u, size_t order, uint8_t mark);
static void compute_reset_mask(struct fhk_graph *G, bm8 *vmask, bm8 *mmask);

static pvalue v_resolve_var(struct u_var *var);
static pvalue v_resolve_env(struct ugraph *u, struct u_env *env);

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
	G->udata = u;
	G->exec_model = G_model_exec;
	G->resolve_var = G_resolve_virtual;
	G->debug_desc_var = G_ddv;
	G->debug_desc_model = G_ddm;

	u_unbind_pos(u);

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
	u_unbind_obj(ret);
	return ret;
}

struct u_var *u_add_var(struct ugraph *u, struct u_obj *obj, lexid varid, struct fhk_var *x,
		const char *name){

	struct u_var *var = &obj->vars[varid];
	vname(var) = arena_asprintf(u->arena, "%s:%s", obj->name, name);
	vtype(var) = V_VAR;
	var->varid = varid;
	var->x = x;
	var->obj = obj;
	x->udata = var;
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
	u->xs[x->idx] = (struct xheader *) ret;
	dv("fhk var[%d] = env %p %s\n", x->idx, ret, name);
	return ret;
}

struct u_comp *u_add_comp(struct ugraph *u, struct fhk_var *x, const char *name){
	struct u_comp *ret = arena_malloc(u->arena, sizeof(*ret));
	vname(ret) = arena_strcpy(u->arena, name);
	vtype(ret) = V_COMP;
	x->udata = ret;
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

void u_init_given_obj(bm8 *init_v, struct u_obj *obj){
	mark_obj(init_v, obj, VM_GIVEN);
}

void u_init_given_envs(bm8 *init_v, struct ugraph *u){
	mark_envs(init_v, u, VM_GIVEN);
}

void u_init_solve(bm8 *init_v, struct fhk_var *y){
	init_v[y->idx] = VM_SOLVE;
}

void u_graph_init(struct ugraph *u, bm8 *init_v){
	struct fhk_graph *G = u->G;
	bm_copy((bm8 *) G->v_bitmaps, init_v, G->n_var);
	bm_zero((bm8 *) G->m_bitmaps, G->n_mod);
}

void u_mark_obj(bm8 *vmask, struct u_obj *obj){
	mark_obj(vmask, obj, 0xff);
}

void u_mark_envs_z(bm8 *vmask, struct ugraph *u, size_t order){
	mark_envs_z(vmask, u, order, 0xff);
}

void u_reset_mark(struct ugraph *u, bm8 *vmask, bm8 *mmask){
	compute_reset_mask(u->G, vmask, mmask);
}

void u_graph_reset(struct ugraph *u, bm8 *reset_v, bm8 *reset_m){
	struct fhk_graph *G = u->G;
	bm_and((bm8 *) G->v_bitmaps, reset_v, G->n_var);
	bm_and((bm8 *) G->m_bitmaps, reset_m, G->n_mod);
}

void u_bind_obj(struct u_obj *obj, w_objref *ref){
	obj->bind = *ref;
}

void u_unbind_obj(struct u_obj *obj){
	obj->bind.vec = NULL;
}

void u_bind_pos(struct ugraph *u, gridpos pos){
	u->update_pos = pos;
}

void u_unbind_pos(struct ugraph *u){
	u->update_pos = GRID_INVALID;
}

void u_solve_vec(struct ugraph *u, struct u_obj *obj, bm8 *reset_v, bm8 *reset_m, w_objvec *v,
		size_t nv, struct fhk_var **xs, void **res, type *types){
	
	if(!v->n_used)
		return;

	// TODO: either update u->update_pos here, or resolve it from the current active object

	obj->bind.vec = v;
	obj->bind.idx = 0;

	size_t n = v->n_used;

	for(size_t i=0;i<n;i++,obj->bind.idx++){
		u_graph_reset(u, reset_v, reset_m);

		for(size_t j=0;j<nv;j++){
			int res = fhk_solve(u->G, xs[j]);
			assert(res == FHK_OK); // TODO error handling goes here
		}

		for(size_t j=0;j<nv;j++){
			tvalue v = vdemote(xs[j]->value, types[j]);
			unsigned stride = tsize(types[j]);
			memcpy(((char *)res[j]) + i*stride, &v, stride);
		}
	}
}

void u_update_vec(struct ugraph *u, struct u_obj *obj, world *w, bm8 *reset_v, bm8 *reset_m,
		w_objvec *v, size_t nv, struct fhk_var **xs, lexid *vars){

	if(!v->n_used)
		return;

	void *bands[nv];
	type types[nv];

	for(size_t i=0;i<nv;i++){
		bands[i] = w_objvec_create_band(w, v, vars[i]);
		types[i] = v->bands[vars[i]].type;
	}

	u_solve_vec(u, obj, reset_v, reset_m, v, nv, xs, bands, types);

	for(size_t i=0;i<nv;i++)
		w_obj_swap(w, v, vars[i], bands[i]);
}

static void mark_obj(bm8 *mark_v, struct u_obj *obj, uint8_t mark){
	for(size_t i=0;i<obj_nv(obj);i++){
		struct u_var *v = &obj->vars[i];
		if(v->x)
			mark_v[v->x->idx] = mark;
	}
}

static void mark_envs(bm8 *mark_v, struct ugraph *u, uint8_t mark){
	for(size_t i=0;i<u_nv(u);i++){
		if(u->xs[i] && vtype(u->xs[i]) == V_ENV)
			mark_v[i] = mark;
	}
}

static void mark_envs_z(bm8 *mark_v, struct ugraph *u, size_t order, uint8_t mark){
	for(size_t i=0;i<u_nv(u);i++){
		if(u->xs[i] && vtype(u->xs[i]) == V_ENV){
			struct u_env *e = (struct u_env *) u->xs[i];
			if(w_env_orderz(e->wenv) > order)
				mark_v[i] = mark;
		}
	}
}

static void compute_reset_mask(struct fhk_graph *G, bm8 *vmask, bm8 *mmask){
	fhk_inv_supp(G, vmask, mmask);

	// Now vmask and mmask contain marked what we want to reset, so invert them
	bm_not(vmask, G->n_var);
	bm_not(mmask, G->n_mod);

	// Finally, these bits shouldn't be touched when stepping
	// Note: (TODO) unstable vars should have the stable bit cleared
	fhk_vbmap keep = { .given=1, .solve=1, .stable=1 };
	bm_or8(vmask, G->n_var, keep.u8);
}

static pvalue v_resolve_var(struct u_var *var){
	struct u_obj *obj = var->obj;
	type t = obj->bind.vec->bands[var->varid].type;
	return vpromote(w_obj_read1(&obj->bind, var->varid), t);
}

static pvalue v_resolve_env(struct ugraph *u, struct u_env *env){
	assert(u->update_pos != GRID_INVALID);
	return vpromote(w_env_readpos(env->wenv, u->update_pos), env->wenv->type);
}

static int G_model_exec(struct fhk_graph *G, void *udata, pvalue *ret, pvalue *args){
	(void)G;

	struct u_model *m = udata;
	return ex_exec(m->f, ret, args);
}

static int G_resolve_virtual(struct fhk_graph *G, void *udata, pvalue *value){
	switch(vtype(udata)){
		case V_VAR: *value = v_resolve_var(udata); break;
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
