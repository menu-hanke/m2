#include "sim.h"
#include "fhk.h"
#include "bitmap.h"
#include "arena.h"
#include "exec.h"
#include "update.h"

#include <stdlib.h>
#include <string.h>

// Note: gvar matches the fhk graph vars - multiple objects can point to this
struct gvar {
	struct fhk_var *x;
	struct var_def *def;

	void *base;
	size_t *pos;
	size_t stride;
};

struct gmodel {
	const char *name;
	ex_func *f;
};

struct gobj {
	size_t pos;
};

struct ufhk {
	arena *arena;
	struct lex *lex;
	// objs & vars indexed by lex id, map to fhk variables
	struct gobj *objs;
	struct gvar *vars;
	struct fhk_graph *G;
};

struct uset {
	lexid objid;
	SVEC(lexid) vars;
	bm8 *init_v;
	bm8 *reset_v, *reset_m;
};

static void start_vec(struct ufhk *u, struct uset *s);
static int update_slice(struct ufhk *u, struct uset *s, sim_slice *slice);
static void activate(struct ufhk *u, sim_objref *ref, struct obj_def *obj);
static void deactivate(struct ufhk *u, struct obj_def *obj);

static void compute_init(struct ufhk *u, struct uset *s);
static void init_given(struct ufhk *u, bm8 *init, struct obj_def *obj);
static void compute_reset(struct ufhk *u, struct uset *s);

static int cb_model_exec(struct fhk_graph *G, void *udata, pvalue *ret, pvalue *args);
static int cb_resolve_virtual(struct fhk_graph *G, void *udata, pvalue *value);
static const char *cb_ddv(void *udata);
static const char *cb_ddm(void *udata);

static void *gvar_varp(struct gvar *gv);
static void gvar_reset(struct gvar *gv);
static void gvar_init(struct gvar *gv, struct var_def *def);

static void init_objs(struct ufhk *u);
static void init_vars(struct ufhk *u);

struct ufhk *ufhk_create(struct lex *lex){
	arena *arena = arena_create(1024);
	struct ufhk *u = arena_malloc(arena, sizeof(*u));
	u->lex = lex;
	u->arena = arena;
	init_objs(u);
	init_vars(u);
	return u;
}

void ufhk_destroy(struct ufhk *u){
	arena_destroy(u->arena);
}

void ufhk_set_var(struct ufhk *u, lexid varid, struct fhk_var *x){
	struct gvar *gv = &u->vars[varid];
	// XXX: array-backed variables should just be implemented in fhk.
	x->is_virtual = 1;
	gv->x = x;
	x->udata = gv;
}

void ufhk_set_model(struct ufhk *u, const char *name, ex_func *f, struct fhk_model *m){
	struct gmodel *gm = arena_malloc(u->arena, sizeof(*gm));
	char *ncopy = arena_alloc(u->arena, strlen(name)+1, 1);
	strcpy(ncopy, name);
	gm->name = ncopy;
	gm->f = f;
	m->udata = gm;
}

void ufhk_set_graph(struct ufhk *u, struct fhk_graph *G){
	u->G = G;
	G->udata = u;
	G->model_exec = cb_model_exec;
	G->resolve_virtual = cb_resolve_virtual;
	G->debug_desc_var = cb_ddv;
	G->debug_desc_model = cb_ddm;
}

int ufhk_update(struct ufhk *u, struct uset *s, sim *sim){
	int ret = 0;
	sim_slice slice;

	for(sim_vec *v=sim_first_rv(sim, s->objid); v; v=sim_next_rv(v)){
		start_vec(u, s);
		sim_used(v, &slice);
		ret = update_slice(u, s, &slice);
		
		// TODO: see note on update_slice
		if(ret)
			break;
	}

	deactivate(u, &SVECE(u->lex->objs, s->objid));
	return ret;
}

int ufhk_update_slice(struct ufhk *u, struct uset *s, sim_slice *slice){
	start_vec(u, s);
	int ret = update_slice(u, s, slice);
	deactivate(u, &SVECE(u->lex->objs, s->objid));
	return ret;
}

struct uset *uset_create(struct ufhk *u, lexid objid, size_t nvars, lexid *vars){
	// Allocate with malloc instead of arena because these can have a shorter life time
	// than the updater (which generally lives through the whole program)
	struct uset *s = malloc(sizeof(*s));
	s->objid = objid;
	s->vars.data = NULL;
	SVEC_RESIZE(s->vars, nvars);
	memcpy(s->vars.data, vars, nvars*sizeof(*vars));
	s->init_v = bm_alloc(u->G->n_var);
	s->reset_v = bm_alloc(u->G->n_var);
	s->reset_m = bm_alloc(u->G->n_mod);
	compute_init(u, s);
	compute_reset(u, s);
	return s;
}

void uset_destroy(uset *s){
	bm_free(s->init_v);
	bm_free(s->reset_v);
	bm_free(s->reset_m);
	free(s->vars.data);
	free(s);
}

static void start_vec(struct ufhk *u, struct uset *s){
	bm_copy((bm8 *) u->G->v_bitmaps, s->init_v, u->G->n_var);
	bm_zero((bm8 *) u->G->m_bitmaps, u->G->n_mod);
}

static int update_slice(struct ufhk *u, struct uset *s, sim_slice *slice){
	activate(u, (sim_objref *) slice, &SVECE(u->lex->objs, s->objid));

	struct obj_def *obj = &SVECE(u->lex->objs, s->objid);
	struct gobj *go = &u->objs[s->objid];

	for(go->pos=slice->from; go->pos<slice->to; go->pos++){
		bm_and2((bm8 *) u->G->v_bitmaps, s->reset_v, u->G->n_var);
		bm_and2((bm8 *) u->G->m_bitmaps, s->reset_m, u->G->n_mod);

		for(size_t i=0;i<s->vars.n;i++){
			// XXX: If needed these varids can be precomputed in s
			lexid varid = SVECE(obj->vars, SVECE(s->vars, i))->id;
			struct gvar *gv = &u->vars[varid];

			// this will crash if someone wants to solve a variable that is not in the graph
			// maybe we could just return an error code if gv->x == NULL
			int res = fhk_solve(u->G, gv->x);

			// TODO: this is not the right thing to do here since it stops all other objects
			// after this from being updated. Maybe call an user-set error handler or return
			// an error code if any errors occurred?
			if(res != FHK_OK)
				return res;

			demote(gvar_varp(gv), gv->def->type, gv->x->mark.value);
		}
	}

	return 0;
}

static void activate(struct ufhk *u, sim_objref *ref, struct obj_def *obj){
	// XXX: This could be optimized by only activating the set of variables possibly
	// needed for calculating the requested variables. This set can be precomputed in ufhk_uset
	// (See: fhk_supp)
	// XXX: Another optimization is to only do this for shared variables
	// (put void **base to gobj, point it at vector base, compute address from var index).
	// Since there are only a few shared vars, this makes activation basically a loop over objids
	
	struct gobj *go = &u->objs[obj->id];
	go->pos = ref->idx;

	for(lexid i=0;i<obj->vars.n;i++){
		lexid varid = SVECE(obj->vars, i)->id;
		struct gvar *gv = &u->vars[varid];
		gv->base = sim_varp_base(ref->vec, i);
		gv->pos = &go->pos;
	}

	for(size_t i=0;i<obj->uprefs.n;i++){
		sim_objref *up = sim_get_upref(ref->vec, i);
		activate(u, up, SVECE(obj->uprefs, i).ref);
	}
}

static void deactivate(struct ufhk *u, struct obj_def *obj){
	// Not necessary but it's nice for debug purposes to crash rather than read garbage
	for(lexid i=0;i<obj->vars.n;i++){
		struct var_def *var = SVECE(obj->vars, i);
		gvar_reset(&u->vars[var->id]);
	}

	for(size_t i=0;i<obj->uprefs.n;i++)
		deactivate(u, SVECE(obj->uprefs, i).ref);
}

static void compute_init(struct ufhk *u, struct uset *s){
	size_t nv = u->G->n_var;

	bm_zero(s->init_v, nv);

	struct obj_def *obj = &SVECE(u->lex->objs, s->objid);
	init_given(u, s->init_v, obj);

	fhk_vbmap solve = { .solve=1 };

	// TODO: maybe return an error instead of crashing if x is null
	for(size_t i=0;i<s->vars.n;i++){
		lexid id = SVECE(obj->vars, SVECE(s->vars, i))->id;
		struct fhk_var *x = u->vars[id].x;
		s->init_v[x->idx] = solve.u8;
	}
}

static void init_given(struct ufhk *u, bm8 *init, struct obj_def *obj){
	fhk_vbmap given = { .given=1 };

	for(lexid i=0;i<obj->vars.n;i++){
		lexid id = SVECE(obj->vars, i)->id;
		struct fhk_var *x = u->vars[id].x;
		if(x)
			init[x->idx] = given.u8;
	}

	for(size_t i=0;i<obj->uprefs.n;i++)
		init_given(u, init, SVECE(obj->uprefs, i).ref);
}

static void compute_reset(struct ufhk *u, struct uset *s){
	size_t nv = u->G->n_var;
	size_t nm = u->G->n_mod;

	bm_zero(s->reset_v, nv);
	bm_zero(s->reset_m, nm);

	struct obj_def *obj = &SVECE(u->lex->objs, s->objid);

	struct fhk_var *vars[obj->vars.n];
	size_t nx = 0;

	// collect fhk variables corresponding to obj vars, note that not all of them
	// are necessarily in the fhk graph
	for(size_t i=0;i<obj->vars.n;i++){
		lexid id = SVECE(obj->vars, i)->id;
		struct fhk_var *x = u->vars[id].x;
		if(x)
			vars[nx++] = x;
	}

	for(size_t i=0;i<nx;i++)
		s->reset_v[vars[i]->idx] = 0xff;

	for(size_t i=0;i<nx;i++)
		fhk_inv_sup(u->G, s->reset_v, s->reset_v, vars[i]);

	// mask now contains each variable(/model) that can possibly change when iterating over obj,
	// negate it to get a mask that resets everything that can change
	bm_not(s->reset_v, nv);
	bm_not(s->reset_m, nm);

	// don't change given or solve bits for any variable
	// TODO: constant like FHK_SOLVER_BITS for mask that the solver changes?
	fhk_vbmap m = { .given=1, .solve=1 };
	bm_or(s->reset_v, nv, m.u8);
}

static int cb_model_exec(struct fhk_graph *G, void *udata, pvalue *ret, pvalue *args){
	(void)G;

	ex_func *f = ((struct gmodel *) udata)->f;
	return ex_exec(f, ret, args);
}

static int cb_resolve_virtual(struct fhk_graph *G, void *udata, pvalue *value){
	(void)G;

	struct gvar *gv = udata;
	*value = promote(gvar_varp(gv), gv->def->type);
	return FHK_OK;
}

static const char *cb_ddv(void *udata){
	// computed vars etc. will not have udata set
	// we could just add names for them but this is only used for debug
	if(!udata)
		return "(computed)";

	return ((struct gvar *) udata)->def->name;
}

static const char *cb_ddm(void *udata){
	return ((struct gmodel *) udata)->name;
}

static void *gvar_varp(struct gvar *gv){
	return ((char *) gv->base) + (*gv->pos)*gv->stride;
}

static void gvar_reset(struct gvar *gv){
	gv->base = NULL;
	gv->pos = NULL;
}

static void gvar_init(struct gvar *gv, struct var_def *def){
	gvar_reset(gv);
	gv->x = NULL;
	gv->def = def;
	const struct type_def *td = get_typedef(def->type);
	gv->stride = td->size;
}

static void init_objs(struct ufhk *u){
	size_t nobj = u->lex->objs.n;
	u->objs = arena_malloc(u->arena, nobj * sizeof(*u->objs));
}

static void init_vars(struct ufhk *u){
	size_t nvar = u->lex->vars.n;

	u->vars = arena_malloc(u->arena, nvar * sizeof(*u->vars));
	for(lexid i=0;i<nvar;i++)
		gvar_init(&u->vars[i], &SVECE(u->lex->vars, i));
}
