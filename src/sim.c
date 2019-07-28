#include "sim.h"
#include "def.h"
#include "list.h"
#include "lex.h"
#include "arena.h"
#include "save.h"
#include "bitmap.h"

#include <stdlib.h>
#include <stdalign.h>
#include <string.h>

#define ALIGN_VECTOR M2_VECTOR_SIZE

struct vec_upref {
	sim_objref owner;
	struct sim_vec *next;
};

struct sim_vec {
	// could have objid/obj_def* here
	size_t n_alloc;
	size_t n_used;
	struct sim_vec *next_root;
	struct vec_upref *uprefs;
	struct sim_vec ***downrefs;
	void *vars[];
};

struct frame {
	unsigned init : 1;
	unsigned inside : 1; /* debug */
	arena *arena;
	save *save;
};

struct objinfo {
	size_t *var_sizes;
};

struct sim {
	// Use an arena for stuff with same lifetime as sim, just for convenience so deallocation
	// doesn't become a huge ritual.
	arena *static_arena;
	struct lex *lex;
	struct objinfo *objinfo;
	struct sim_vec **rootvecs;
	unsigned depth;
	struct frame stack[SIM_MAX_DEPTH];
};

static void init_objs(struct sim *sim);
static void init_alloc_info(struct sim *sim, struct objinfo *oi, struct obj_def *obj);
static void init_stack(struct sim *sim);

static void destroy_stack(struct sim *sim);

static void f_init(struct frame *f);
static void f_destroy(struct frame *f);
static void f_enter(struct frame *f);
static void f_exit(struct frame *f);
static void *f_alloc(struct frame *f, size_t size, size_t align);

static void allocfv(struct sim *sim, void **vars, struct sim_vec ***downrefs, lexid objid,
		size_t n);
static struct sim_vec *findv(struct sim *sim, lexid objid, sim_objref *uprefs);
static struct sim_vec *createv(struct sim *sim, lexid objid, sim_objref *uprefs, size_t n);
static void insertv(struct sim *sim, struct sim_vec *vec, lexid objid, sim_objref *uprefs);
static void resizev(struct sim *sim, struct sim_vec *vec, lexid objid, size_t n);
static void ensurecapv(struct sim *sim, struct sim_vec *vec, lexid objid, size_t n);
static void initslicev(struct sim *sim, struct sim_vec *vec, lexid objid, size_t from, size_t to);

static void sp_savestate(struct sim *sim, save *save);
static void sp_savev(struct sim *sim, save *save, struct sim_vec *vec, lexid objid);

#define TOP(sim) (&((sim)->stack[(sim)->depth]))
#define PREV(sim) (&((sim)->stack[(sim)->depth-1]))
static void *static_malloc(struct sim *sim, size_t size);
static int same_ref(sim_objref *a, sim_objref *b);
static size_t nextvsize(size_t n);

struct sim *sim_create(struct lex *lex){
	arena *static_arena = arena_create(1024);
	struct sim *sim = arena_malloc(static_arena, sizeof(*sim));
	sim->static_arena = static_arena;
	sim->lex = lex;
	init_stack(sim);
	init_objs(sim);
	return sim;
}

void sim_destroy(struct sim *sim){
	destroy_stack(sim);
	arena_destroy(sim->static_arena);
}

void *sim_alloc(struct sim *sim, size_t size, size_t align){
	return f_alloc(TOP(sim), size, align);
}

void sim_allocv(struct sim *sim, sim_slice *pos, lexid objid, sim_objref *uprefs, size_t n){
	struct sim_vec *vec = findv(sim, objid, uprefs);

	if(vec)
		ensurecapv(sim, vec, objid, n);
	else
		vec = createv(sim, objid, uprefs, n);

	initslicev(sim, vec, objid, vec->n_used, vec->n_used+n);

	pos->vec = vec;
	pos->from = vec->n_used;
	pos->to = vec->n_used + n;
	vec->n_used += n;
}

int sim_first(struct sim *sim, sim_iter *it, lexid objid, sim_objref *upref, int uprefidx){
	struct sim_vec *v;

	if(upref){
		struct obj_def *obj = &sim->lex->objs.data[objid];
		int backidx = obj->uprefs.data[uprefidx].back_idx;
		v = upref->vec->downrefs[backidx][upref->idx];
		while(v && !v->n_used)
			v = v->uprefs[uprefidx].next;
	}else{
		v = sim->rootvecs[objid];
		while(v && !v->n_used)
			v = v->next_root;
		uprefidx = -1;
	}

	if(!v)
		return SIM_ITER_END;

	it->ref.vec = v;
	it->ref.idx = 0;
	it->upref = uprefidx;

	return SIM_ITER_NEXT;
}

int sim_next(sim_iter *it){
	if(++it->ref.idx < it->ref.vec->n_used)
		return SIM_ITER_NEXT;

	struct sim_vec *v = it->ref.vec;

	if(it->upref >= 0){
		do {
			v = v->uprefs[it->upref].next;
		} while(v && !v->n_used);
	}else{
		do {
			v = v->next_root;
		} while(v && !v->n_used);
	}

	if(!v)
		return SIM_ITER_END;

	it->ref.vec = v;
	it->ref.idx = 0;

	return SIM_ITER_NEXT;
}

struct sim_vec *sim_first_rv(struct sim *sim, lexid objid){
	return sim->rootvecs[objid];
}

struct sim_vec *sim_next_rv(struct sim_vec *prev){
	return prev->next_root;
}

void sim_used(struct sim_vec *vec, sim_slice *slice){
	slice->vec = vec;
	slice->from = 0;
	slice->to = vec->n_used;
}

void *sim_varp(struct sim *sim, sim_objref *ref, lexid objid, lexid varid){
	struct objinfo *oi = &sim->objinfo[objid];
	return ((char *) ref->vec->vars[varid]) + oi->var_sizes[varid]*ref->idx;
}

void *sim_varp_base(struct sim_vec *vec, lexid varid){
	return vec->vars[varid];
}

pvalue sim_read1p(struct sim *sim, sim_objref *ref, lexid objid, lexid varid){
	struct obj_def *obj = &sim->lex->objs.data[objid];
	return promote(sim_varp(sim, ref, objid, varid), obj->vars.data[varid]->type);
}

void sim_write1p(struct sim *sim, sim_objref *ref, lexid objid, lexid varid, pvalue value){
	struct obj_def *obj = &sim->lex->objs.data[objid];
	demote(sim_varp(sim, ref, objid, varid), obj->vars.data[varid]->type, value);
}

sim_objref *sim_get_upref(struct sim_vec *vec, int uprefidx){
	return &vec->uprefs[uprefidx].owner;
}

int sim_enter(struct sim *sim){
	if(sim->depth+1 >= SIM_MAX_DEPTH)
		return SIM_EDEPTH_LIMIT;

	sim->depth++;
	struct frame *top = TOP(sim);
	f_enter(top);

	// save sim state as it was when we entered the frame,
	// this can be restored by sim_rollback() as many times as the caller wants
	top->save = save_create(top->arena);
	sp_savestate(sim, top->save);

	return SIM_OK;
}

void sim_rollback(struct sim *sim){
	save_rollback(TOP(sim)->save);
}

int sim_exit(struct sim *sim){
	if(!sim->depth)
		return SIM_EINVALID_FRAME;

	f_exit(TOP(sim));
	sim->depth--;

	return SIM_OK;
}

static void init_objs(struct sim *sim){
	size_t nobj = sim->lex->objs.n;

	sim->objinfo = static_malloc(sim, nobj * sizeof(*sim->objinfo));
	for(size_t i=0;i<nobj;i++)
		init_alloc_info(sim, &sim->objinfo[i], &sim->lex->objs.data[i]);

	sim->rootvecs = static_malloc(sim, nobj * sizeof(*sim->rootvecs));
	memset(sim->rootvecs, 0, nobj * sizeof(*sim->rootvecs));
}

static void init_alloc_info(struct sim *sim, struct objinfo *oi, struct obj_def *obj){
	// TODO hot/cold attrs, const attrs?
	// Note: this doesn't take into account alignment.
	// alignment is currently handled automatically since each allocation count is
	// a multiple of alignment
	
	size_t nvar = obj->vars.n;
	oi->var_sizes = static_malloc(sim, nvar * sizeof(*oi->var_sizes));

	for(size_t i=0;i<nvar;i++){
		const struct type_def *td = get_typedef(obj->vars.data[i]->type);
		oi->var_sizes[i] = td->size;
	}
}

static void init_stack(struct sim *sim){
	memset(sim->stack, 0, sizeof(struct frame) * SIM_MAX_DEPTH);
	sim->depth = 0;
	f_enter(TOP(sim));
}

static void destroy_stack(struct sim *sim){
	for(int i=0;i<SIM_MAX_DEPTH;i++){
		if(sim->stack[i].init)
			f_destroy(&sim->stack[i]);
	}
}

static void f_init(struct frame *f){
	assert(!f->init);
	f->init = 1;
	f->arena = arena_create(SIM_ARENA_SIZE);
}

static void f_destroy(struct frame *f){
	assert(f->init);
	DD(f->init = 0);
	arena_destroy(f->arena);
}

static void f_enter(struct frame *f){
	assert(!f->inside);
	DD(f->inside = 1);

	if(!f->init)
		f_init(f);

	arena_reset(f->arena);
}

static void f_exit(struct frame *f){
	assert(f->inside);
	DD(f->inside = 0);
}

static void *f_alloc(struct frame *f, size_t size, size_t align){
	return arena_alloc(f->arena, size, align);
}

static void allocfv(struct sim *sim, void **vars, struct sim_vec ***downrefs, lexid objid,
		size_t n){

	struct objinfo *oi = &sim->objinfo[objid];
	struct obj_def *obj = &sim->lex->objs.data[objid];

	for(size_t i=0;i<obj->vars.n;i++)
		vars[i] = sim_alloc(sim, n*oi->var_sizes[i], ALIGN_VECTOR);

	for(size_t i=0;i<obj->downrefs.n;i++)
		downrefs[i] = sim_alloc(sim, n*sizeof(*downrefs), alignof(*downrefs));
}

static struct sim_vec *findv(struct sim *sim, lexid objid, sim_objref *uprefs){
	struct obj_def *obj = &sim->lex->objs.data[objid];
	size_t nup = obj->uprefs.n;

	if(nup){
		// has atleast one upref, find it by picking the first upref and following
		// its vector list
		int back_idx = obj->uprefs.data[0].back_idx;
		struct sim_vec *v = uprefs[0].vec->downrefs[back_idx][uprefs[0].idx];

		for(; v; v=v->uprefs[0].next){
			// first ref is always same so we can check from 1
			for(size_t i=1;i<nup;i++){
				if(!same_ref(&v->uprefs[i].owner, &uprefs[i]))
					continue;
			}

			return v;
		}

		return NULL;
	}

	// no uprefs, it has to be root
	return sim->rootvecs[objid];
}

static struct sim_vec *createv(struct sim *sim, lexid objid, sim_objref *uprefs, size_t n){
	struct obj_def *obj = &sim->lex->objs.data[objid];
	struct sim_vec *ret = sim_alloc(sim, sizeof(*ret) + obj->vars.n*sizeof(void *), alignof(*ret));

	size_t ndr = obj->downrefs.n;
	if(ndr)
		ret->downrefs = sim_alloc(sim, ndr*sizeof(*ret->downrefs), alignof(*ret->downrefs));

	size_t nur = obj->uprefs.n;
	if(nur)
		ret->uprefs = sim_alloc(sim, nur*sizeof(*ret->uprefs), alignof(*ret->uprefs));
	
	n = nextvsize(n);
	allocfv(sim, ret->vars, ret->downrefs, objid, n);
	ret->n_alloc = n;
	ret->n_used = 0;

	insertv(sim, ret, objid, uprefs);

	return ret;
}

static void insertv(struct sim *sim, struct sim_vec *vec, lexid objid, sim_objref *uprefs){
	struct obj_def *obj = &sim->lex->objs.data[objid];

	for(size_t i=0;i<obj->uprefs.n;i++){
		struct obj_ref *r = &obj->uprefs.data[i];
		struct sim_vec *tail = uprefs[i].vec->downrefs[r->back_idx][uprefs[i].idx];
		vec->uprefs[i].next = tail;
		vec->uprefs[i].owner = uprefs[i];
		uprefs[i].vec->downrefs[r->back_idx][uprefs[i].idx] = vec;
	}

	vec->next_root = sim->rootvecs[objid];
	sim->rootvecs[objid] = vec;
}

static void resizev(struct sim *sim, struct sim_vec *vec, lexid objid, size_t n){
	struct obj_def *obj = &sim->lex->objs.data[objid];
	struct objinfo *oi = &sim->objinfo[objid];
	void *vars[obj->vars.n];
	struct sim_vec **downrefs[obj->downrefs.n];
	allocfv(sim, vars, downrefs, objid, n);

	for(size_t i=0;i<obj->vars.n;i++)
		memcpy(vars[i], vec->vars[i], vec->n_used*oi->var_sizes[i]);

	for(size_t i=0;i<obj->downrefs.n;i++)
		memcpy(downrefs[i], vec->downrefs[i], vec->n_used*sizeof(struct sim_vec *));

	vec->n_alloc = n;
	memcpy(vec->vars, vars, obj->vars.n*sizeof(*vec->vars));
	memcpy(vec->downrefs, downrefs, obj->downrefs.n*sizeof(*vec->downrefs));
}

static void ensurecapv(struct sim *sim, struct sim_vec *vec, lexid objid, size_t n){
	size_t need = vec->n_used + n;
	if(vec->n_alloc >= need)
		return;

	size_t na = vec->n_alloc;
	while(na < need)
		na *= 2;

	resizev(sim, vec, objid, na);
}

static void initslicev(struct sim *sim, struct sim_vec *vec, lexid objid, size_t from, size_t to){
	struct obj_def *obj = &sim->lex->objs.data[objid];

	for(size_t i=0;i<obj->downrefs.n;i++)
		memset(&vec->downrefs[i][from], 0, (to-from)*sizeof(struct downref *));
}

static void sp_savestate(struct sim *sim, save *save){
	// XXX: saving is currently implemented as recursively saving the whole sim state
	// the sim could be a bit smarter about this, for example only saving the vector header
	// and then saving the vector contents if they are changed before the next save point
	
	// most things in the sim struct (frame info, objinfo etc) don't need to be saved.
	// just save vector headers and contents
	
	save_copy(save, sim->rootvecs, sim->lex->objs.n * sizeof(*sim->rootvecs));

	for(lexid i=0;i<sim->lex->objs.n;i++){
		for(struct sim_vec *v=sim->rootvecs[i]; v; v=v->next_root)
			sp_savev(sim, save, v, i);
	}
}

static void sp_savev(struct sim *sim, save *save, struct sim_vec *vec, lexid objid){
	struct obj_def *obj = &sim->lex->objs.data[objid];

	save_copy(save, vec, sizeof(*vec) + obj->vars.n*sizeof(void *));

	if(obj->downrefs.n)
		save_copy(save, vec->downrefs, obj->downrefs.n*sizeof(*vec->downrefs));

	if(obj->uprefs.n)
		save_copy(save, vec->uprefs, obj->uprefs.n*sizeof(*vec->uprefs));

	if(!vec->n_used)
		return;

	struct objinfo *oi = &sim->objinfo[objid];

	for(size_t i=0;i<obj->vars.n;i++)
		save_copy(save, vec->vars[i], vec->n_used*oi->var_sizes[i]);

	for(size_t i=0;i<obj->downrefs.n;i++)
		save_copy(save, vec->downrefs[i], vec->n_used*sizeof(**vec->downrefs));
}

static void *static_malloc(struct sim *sim, size_t size){
	return arena_malloc(sim->static_arena, size);
}

static int same_ref(sim_objref *a, sim_objref *b){
	return a->vec == b->vec && a->idx == b->idx;
}

static size_t nextvsize(size_t n){
	// round to next power of 2
	// (there's probably a bit hack to do this but i assume gcc can optimize)
	size_t ret = 1;
	while(ret < n)
		ret *= 2;
	return ret;
}
