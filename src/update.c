#include "fhk.h"
#include "exec.h"
#include "arena.h"
#include "sim.h"
#include "def.h"

#include <stddef.h>
#include <stdlib.h>
#include <string.h>

#define USET_ENVID (~0)

enum {
	V_VAR      = 0,
	V_ENV      = 1,
	V_COMPUTED = 2
};

struct var {
	int type;

	union {
		/* V_SIM */
		struct {
			struct var_def *vdef;
			lexid varid;
		};

		/* V_ENV */
		struct {
			struct env_def *edef;
			sim_env *senv;
		};

		/* V_COMPUTED */
		struct {
			char *name;
		};
	};
};

struct model {
	char *name;
	ex_func *f;
};

struct ugraph {
	arena *arena;
	sim *sim;
	struct lex *lex;
	struct fhk_graph *G;
	struct fhk_var **envs;
	struct fhk_var ***vars;

	sim_objref u_objref;
};

struct uset {
	bm8 *init_v;
	bm8 *reset_v, *reset_m;
	lexid objid;
	size_t nv;
	lexid varids[];
};

static void update_cell(struct ugraph *u, struct uset *s, gridpos cell);

static void s_vars_init(struct ugraph *u, struct uset *s);
static void s_vars_reset(struct ugraph *u, struct uset *s);
static void s_envs_init(struct ugraph *u, struct uset *s);
static void s_envs_reset(struct ugraph *u, struct uset *s);
static struct uset *s_create_uset(struct ugraph *u, size_t nv, lexid *varids);

static void mark_envs_given(struct ugraph *u, bm8 *bm);

static int G_model_exec(struct fhk_graph *G, void *udata, pvalue *ret, pvalue *args);
static int G_resolve_virtual(struct fhk_graph *G, void *udata, pvalue *value);
static const char *G_ddv(void *udata);
static const char *G_ddm(void *udata);

struct ugraph *u_create(sim *sim, struct lex *lex, struct fhk_graph *G){
	arena *arena = arena_create(1024);
	struct ugraph *u = arena_malloc(arena, sizeof(*u));
	u->arena = arena;
	u->sim = sim;
	u->lex = lex;

	u->envs = arena_malloc(arena, VECN(lex->envs)*sizeof(*u->envs));
	memset(u->envs, 0, VECN(lex->envs)*sizeof(*u->envs));
	u->vars = arena_malloc(arena, VECN(lex->objs)*sizeof(*u->vars));
	for(lexid i=0;i<VECN(lex->objs);i++){
		struct obj_def *obj = &VECE(lex->objs, i);
		u->vars[i] = arena_malloc(arena, VECN(obj->vars)*sizeof(**u->vars));
		memset(u->vars[i], 0, VECN(obj->vars)*sizeof(**u->vars));
	}

	u->G = G;
	G->udata = u;
	G->model_exec = G_model_exec;
	G->resolve_virtual = G_resolve_virtual;
	G->debug_desc_var = G_ddv;
	G->debug_desc_model = G_ddm;

	return u;
}

void u_destroy(struct ugraph *u){
	arena_destroy(u->arena);
}

void u_link_var(struct ugraph *u, struct fhk_var *x, struct obj_def *obj, struct var_def *var){
	struct var *v = arena_malloc(u->arena, sizeof(*v));
	v->type = V_VAR;
	v->vdef = var;
	v->varid = var->id;
	x->udata = v;
	x->is_virtual = 1;
	u->vars[obj->id][var->id] = x;
	dv("fhk var[%d] = lex var[%d] %s of obj[%d] %s\n",
			x->idx, var->id, var->name, obj->id, obj->name);
}

void u_link_env(struct ugraph *u, struct fhk_var *x, struct env_def *env){
	struct var *v = arena_malloc(u->arena, sizeof(*v));
	v->type = V_ENV;
	v->edef = env;
	v->senv = sim_get_env(u->sim, env->id);
	x->udata = v;
	x->is_virtual = 1;
	u->envs[env->id] = x;
	dv("fhk var[%d] = env[%d] %s\n", x->idx, env->id, env->name);
}

void u_link_computed(struct ugraph *u, struct fhk_var *x, const char *name){
	struct var *v = arena_malloc(u->arena, sizeof(*v));
	v->type = V_COMPUTED;
	size_t namelen = strlen(name) + 1;
	v->name = arena_salloc(u->arena, namelen);
	memcpy(v->name, name, namelen);
	x->udata = v;
	x->is_virtual = 1;
	dv("fhk var[%d] = computed %s\n", x->idx, name);
}

void u_link_model(struct ugraph *u, struct fhk_model *m, const char *name, ex_func *f){
	struct model *mdl = arena_malloc(u->arena, sizeof(*mdl));
	size_t namelen = strlen(name) + 1;
	mdl->name = arena_salloc(u->arena, namelen);
	memcpy(mdl->name, name, namelen);
	mdl->f = f;
	m->udata = mdl;
	dv("fhk model[%d] = model[%p] %s\n", m->idx, f, name);
}

struct uset *uset_create_vars(struct ugraph *u, lexid objid, size_t nv, lexid *varids){
	struct uset *s = s_create_uset(u, nv, varids);
	s->objid = objid;
	s_vars_init(u, s);
	s_vars_reset(u, s);
	return s;
}

struct uset *uset_create_envs(struct ugraph *u, size_t nv, lexid *envids){
	struct uset *s = s_create_uset(u, nv, envids);
	s->objid = USET_ENVID;
	s_envs_init(u, s);
	s_envs_reset(u, s);
	return s;
}

void uset_destroy(struct uset *s){
	bm_free(s->init_v);
	bm_free(s->reset_v);
	bm_free(s->reset_m);
	free(s);
}

void uset_update(struct ugraph *u, struct uset *s){
	struct grid *objgrid = sim_get_objgrid(u->sim, s->objid);
	gridpos max = grid_max(objgrid->order);

	for(gridpos i=0;i<max;i++)
		update_cell(u, s, i);
}

static void update_cell(struct ugraph *u, struct uset *s, gridpos cell){
	// TODO: update for envs, that should loop over gridpos instead of vector elements

	struct grid *objgrid = sim_get_objgrid(u->sim, s->objid);
	sim_objvec *v = grid_data(objgrid, cell);

	if(!v->n_used)
		return;

	u->u_objref.vec = v;

	// (1) totally reset graph, this also sets the correct given/solve flags
	struct fhk_graph *G = u->G;
	bm_copy((bm8 *) G->v_bitmaps, s->init_v, G->n_var);
	bm_zero((bm8 *) G->m_bitmaps, G->n_mod);

	// (2) collect new vectors to put the results in, this is done for 2 reasons
	//   - since we just change the pointer, the old data doesn't need to be copied to safety
	//   - we avoid overwriting old data since that could in theory change the results of some models
	size_t nv = s->nv;
	sim_vband bands[nv];
	for(size_t i=0;i<nv;i++){
		lexid varid = s->varids[i];
		bands[i].type = v->bands[varid].type;
		bands[i].stride_bits = v->bands[varid].stride_bits;
		bands[i].data = sim_alloc_band(u->sim, v, varid);
	}

	// (3) collect the fhk var pointers here since we are going to go over this array a lot
	struct fhk_var *x[nv];
	for(size_t i=0;i<nv;i++)
		x[i] = u->vars[s->objid][s->varids[i]];

	// (4) solve!
	size_t n = v->n_used;
	for(size_t i=0;i<n;i++){
		bm_and2((bm8 *) G->v_bitmaps, s->reset_v, G->n_var);
		bm_and2((bm8 *) G->m_bitmaps, s->reset_m, G->n_mod);
		u->u_objref.idx = i;

		for(size_t j=0;j<nv;j++){
			int res = fhk_solve(G, x[j]);
			assert(!res); // TODO error handling goes here
		}

		for(size_t j=0;j<nv;j++)
			demote(sim_vb_varp(&bands[j], i), bands[j].type, x[j]->mark.value);
	}

	// (5) replace only the changed pointers, the old data is safe generally in the previous
	// branch arena
	for(size_t i=0;i<nv;i++)
		sim_obj_swap(u->sim, v, s->varids[i], bands[i].data);
}

static void s_vars_init(struct ugraph *u, struct uset *s){
	size_t nv = u->G->n_var;
	bm_zero(s->init_v, nv);

	// envs are always given
	mark_envs_given(u, s->init_v);

	struct obj_def *obj = &VECE(u->lex->objs, s->objid);
	fhk_vbmap given = { .given=1 };
	fhk_vbmap solve = { .solve=1 };

	// first set all vars on the object to given
	for(lexid i=0;i<VECN(obj->vars);i++){
		struct fhk_var *x = u->vars[s->objid][i];
		if(x)
			s->init_v[x->idx] = given.u8;
	}

	// then set the requested ones to solve
	for(size_t i=0;i<s->nv;i++){
		struct fhk_var *x = u->vars[s->objid][s->varids[i]];
		s->init_v[x->idx] = solve.u8;
	}
}

static void s_vars_reset(struct ugraph *u, struct uset *s){
	size_t nv = u->G->n_var;
	size_t nm = u->G->n_mod;

	bm_zero(s->reset_v, nv);
	bm_zero(s->reset_m, nm);

	// each iteration the following is reset:
	// (1) all object variables
	// (2) envs with a smaller grid than the object grid
	// (3) everything depending on (1) & (2), above the requested vars
	
	// (1)
	struct obj_def *obj = &VECE(u->lex->objs, s->objid);
	for(lexid i=0;i<VECN(obj->vars);i++){
		struct fhk_var *x = u->vars[s->objid][i];
		if(x)
			s->reset_v[x->idx] = 0xff;
	}

	// (2)
	size_t order = sim_get_objgrid(u->sim, s->objid)->order;
	for(lexid i=0;i<VECN(u->lex->envs);i++){
		// Note: if the zoom is changed this mask needs to be recalculated (TODO)
		struct fhk_var *x = u->envs[i];
		if(x){
			size_t xord = sim_env_orderz(sim_get_env(u->sim, i));
			if(xord > order)
				s->reset_v[x->idx] = 0xff;
		}
	}

	// (3)
	// zero the relevant indices first, fhk_inv_supp will set them
	for(size_t i=0;i<s->nv;i++){
		struct fhk_var *x = u->vars[s->objid][s->varids[i]];
		s->reset_v[x->idx] = 0;
	}
	for(size_t i=0;i<s->nv;i++){
		struct fhk_var *x = u->vars[s->objid][s->varids[i]];
		fhk_inv_supp(u->G, s->reset_v, s->reset_m, x);
	}

	// now each thing to reset is marked with 0xff, but we want to mask them out so negate them
	bm_not(s->reset_v, nv);
	bm_not(s->reset_m, nm);

	// finally, don't mask out given and solve bits
	fhk_vbmap keep = { .given=1, .solve=1 };
	bm_or(s->reset_v, nv, keep.u8);
}

static void s_envs_init(struct ugraph *u, struct uset *s){
	(void)u;
	(void)s;
	assert(!"TODO");
}

static void s_envs_reset(struct ugraph *u, struct uset *s){
	(void)u;
	(void)s;
	assert(!"TODO");
}

static struct uset *s_create_uset(struct ugraph *u, size_t nv, lexid *varids){
	// use malloc here instead of arena since uset lifetime can be shorter than ugraph
	struct uset *s = malloc(sizeof(*s) + nv*sizeof(lexid));
	s->nv = nv;
	memcpy(s->varids, varids, nv*sizeof(*varids));
	s->init_v = bm_alloc(u->G->n_var);
	s->reset_v = bm_alloc(u->G->n_var);
	s->reset_m = bm_alloc(u->G->n_mod);
	return s;
}

static void mark_envs_given(struct ugraph *u, bm8 *bm){
	fhk_vbmap given = { .given=1 };

	for(lexid i=0;i<VECN(u->lex->envs);i++){
		struct fhk_var *x = u->envs[i];
		if(x)
			bm[x->idx] = given.u8;
	}
}

static int G_model_exec(struct fhk_graph *G, void *udata, pvalue *ret, pvalue *args){
	(void)G;

	struct model *m = udata;
	return ex_exec(m->f, ret, args);
}

static int G_resolve_virtual(struct fhk_graph *G, void *udata, pvalue *value){
	struct ugraph *u = G->udata;
	struct var *v = udata;
	
	switch(v->type){
		case V_VAR: 
			*value = sim_obj_read1(&u->u_objref, v->varid);
			break;

		case V_ENV: {
			gridpos pos = sim_obj_read1(&u->u_objref, VARID_POSITION).p;
			*value = sim_env_readpos(v->senv, pos);
			break;
		}

		default: UNREACHABLE();
	}

	return FHK_OK;
}

static const char *G_ddv(void *udata){
	struct var *v = udata;

	switch(v->type){
		case V_VAR:
			return v->vdef->name;
		case V_ENV:
			return v->edef->name;
		case V_COMPUTED:
			return v->name;
	}

	UNREACHABLE();
}

static const char *G_ddm(void *udata){
	struct model *m = udata;
	return m->name;
}
