#include "lex.h"
#include "arena.h"
#include "grid.h"
#include "save.h"
#include "list.h"
#include "def.h"
#include "sim.h"

#include <stddef.h>
#include <string.h>
#include <stdlib.h>
#include <stdalign.h>
#include <alloca.h>

#define VEC_ALIGN M2_VECTOR_SIZE

static_assert((SIM_INIT_VEC_SIZE % M2_VECTOR_SIZE) == 0);
static_assert((SIM_MAX_VAR % (8*BITMAP_ALIGN)) == 0);

struct env {
	type type;
	size_t zoom_order;
	gridpos zoom_mask;
	struct grid grid;
};

struct branchinfo {
	size_t nb;
	size_t next;
	sim_branchid ids[];
};

struct frame {
	unsigned init : 1;
	unsigned inside : 1; /* debug */

	arena *arena;
	save *save;
	struct branchinfo *branches;
};

struct tmp_stackp {
	struct tmp_stackp *prev;
	arena_ptr ap;
};

struct sim {
	arena *static_arena;

	size_t n_obj;
	struct grid *objs;
	size_t n_env;
	struct env *envs;

	unsigned depth;
	struct frame stack[SIM_MAX_DEPTH];

	// XXX: sim doesn't really need temp memory allocation so these can be removed?
	arena *tmp_arena;
	struct tmp_stackp *tmp_sp;
};

static void init_objs(struct sim *sim, struct lex *lex);
static void init_objgrid(struct sim *sim, struct grid *g, struct obj_def *obj);
static void init_envs(struct sim *sim, struct lex *lex);
static void init_envgrid(struct sim *sim, struct env *e, struct env_def *def);
static void init_frame(struct sim *sim);

static void create_savepoint(struct sim *sim, save *sp);
static size_t next_cell_allocvs(struct sim *sim, struct grid *g, size_t n, gridpos *pos,
		sim_objref *refs);
static size_t next_cell_deletevs(struct sim *sim, struct grid *g, size_t n, sim_objref *refs);

static void v_ensure_cap(struct sim *sim, sim_objvec *v, size_t n);
static size_t v_alloc(struct sim *sim, sim_objvec *v, size_t n);

static void destroy_stack(struct sim *sim);

static void f_init(struct frame *f);
static void f_destroy(struct frame *f);
static void f_enter(struct frame *f);
static save *f_savepoint(struct frame *f);
static void f_restore(struct frame *f);
static void f_branch(struct frame *f, size_t n, sim_branchid *ids);
static sim_branchid f_next_branch(struct frame *f);
static void f_exit(struct frame *f);
static void *f_alloc(struct frame *f, size_t size, size_t align);

#define TOP(sim) (&((sim)->stack[(sim)->depth]))
#define PREV(sim) (&((sim)->stack[(sim)->depth-1]))
static void *static_malloc(struct sim *sim, size_t size);
static int cmp_gridpos(const void *a, const void *b);
static int cmp_objref(const void *a, const void *b);

struct sim *sim_create(struct lex *lex){
	arena *static_arena = arena_create(SIM_STATIC_ARENA_SIZE);
	struct sim *sim = arena_malloc(static_arena, sizeof(*sim));
	sim->static_arena = static_arena;
	sim->tmp_arena = arena_create(SIM_TMP_ARENA_SIZE);
	init_objs(sim, lex);
	init_envs(sim, lex);
	init_frame(sim);
	return sim;
}

void sim_destroy(struct sim *sim){
	destroy_stack(sim);
	arena_destroy(sim->tmp_arena);
	arena_destroy(sim->static_arena);
}

struct grid *sim_get_envgrid(struct sim *sim, lexid envid){
	assert(envid < sim->n_env);
	return &sim->envs[envid].grid;
}

struct grid *sim_get_objgrid(sim *sim, lexid objid){
	assert(objid < sim->n_obj);
	return &sim->objs[objid];
}

size_t sim_env_effective_order(struct sim *sim, lexid envid){
	assert(envid < sim->n_env);
	struct env *e = &sim->envs[envid];
	return e->zoom_order ? e->zoom_order : e->grid.order;
}

void *S_obj_varp(sim_objref *ref, lexid varid){
	struct tvec *v = &ref->vec->bands[varid];
	return tvec_varp(v, ref->idx);
}

pvalue S_obj_read(sim_objref *ref, lexid varid){
	return promote(S_obj_varp(ref, varid), ref->vec->bands[varid].type);
}

void *S_envp(struct sim *sim, lexid envid, gridpos pos){
	struct env *e = &sim->envs[envid];

	if(e->zoom_order)
		pos = grid_zoom_up(pos & e->zoom_mask, POSITION_ORDER, e->zoom_order);
	else
		pos = grid_zoom_up(pos, POSITION_ORDER, e->grid.order);

	return grid_data(&e->grid, pos);
}

pvalue S_read_env(struct sim *sim, lexid envid, gridpos pos){
	return promote(S_envp(sim, envid, pos), sim->envs[envid].type);
}

void S_env_vec(struct sim *sim, struct pvec *v, lexid envid){
	struct env *e = &sim->envs[envid];
	v->type = e->type;
	v->n = grid_max(e->grid.order);
	v->data = e->grid.data;
}

void S_allocv(struct sim *sim, sim_objref *refs, lexid objid, size_t n, gridpos *pos){
	// NOTE: this modifies pos!
	// TODO: a better sort here is a good idea
	qsort(pos, n, sizeof(gridpos), cmp_gridpos);
	S_allocvs(sim, refs, objid, n, pos);
}

void S_allocvs(struct sim *sim, sim_objref *refs, lexid objid, size_t n, gridpos *pos){
	// entries going in the same cell are now guaranteed to be sequential due to Z-ordering
	
	struct grid *g = &sim->objs[objid];

	while(n){
		size_t nv = next_cell_allocvs(sim, g, n, pos, refs);
		n -= nv;
		pos += nv;
		refs += nv;
	}
}

void S_deletev(struct sim *sim, lexid objid, size_t n, sim_objref *refs){
	// same as allocv, a better sort here would be good
	// (though this function is probably called less often since objects can be just left
	// to die with the branch)
	qsort(refs, n, sizeof(*refs), cmp_objref);
	S_deletevs(sim, objid, n, refs);
}

void S_deletevs(struct sim *sim, lexid objid, size_t n, sim_objref *refs){
	struct grid *g = &sim->objs[objid];

	while(n){
		size_t nv = next_cell_deletevs(sim, g, n, refs);
		n -= nv;
		refs += nv;
	}
}

// return a new simd aligned uninitialized band matching the specified band
void S_allocb(struct sim *sim, struct tvec *v, sim_objvec *vec, lexid varid){
	struct tvec *band = &vec->bands[varid];
	v->type = band->type;
	v->stride = band->stride;
	v->data = f_alloc(TOP(sim), v->stride*vec->n_alloc, VEC_ALIGN);
}

void S_savepoint(struct sim *sim){
	create_savepoint(sim, f_savepoint(TOP(sim)));
}

void S_restore(struct sim *sim){
	f_restore(TOP(sim));
}

void S_enter(struct sim *sim){
	// TODO error handling
	assert(sim->depth+1 < SIM_MAX_DEPTH);
	sim->depth++;
	f_enter(TOP(sim));
}

void S_exit(struct sim *sim){
	assert(sim->depth > 0);
	f_exit(TOP(sim));
	sim->depth--;
}

// Note: after calling this function, the only sim calls to this frame allowed are:
// * calling S_next_branch() until it returns 0
// * calling S_exit() to exit the frame
sim_branchid S_branch(struct sim *sim, size_t n, sim_branchid *branches){
	// TODO: logic concerning replaying simulations or specific branches goes here
	// e.g. when replaying, only use 1 (or m for m<=n) branches
	f_branch(TOP(sim), n, branches);

	// since simulating on this branch is forbidden now, we only need to make a savepoint
	// if there are more than 1 branch (this state will be forgotten anyway by the relevant
	// upper level branch anyway)
	if(n > 1)
		S_savepoint(sim);

	sim_branchid ret = f_next_branch(TOP(sim));
	if(ret != SIM_NO_BRANCH)
		S_enter(sim);

	// TODO: forking could go here?
	return ret;
}

sim_branchid S_next_branch(struct sim *sim){
	sim_branchid ret = f_next_branch(TOP(sim));

	if(ret != SIM_NO_BRANCH){
		S_exit(sim);
		S_restore(sim);
		S_enter(sim);
	}

	return ret;
}

static void init_objs(struct sim *sim, struct lex *lex){
	sim->n_obj = VECN(lex->objs);
	sim->objs = static_malloc(sim, sim->n_obj * sizeof(*sim->objs));
	for(lexid i=0;i<sim->n_obj;i++)
		init_objgrid(sim, &sim->objs[i], &VECE(lex->objs, i));
}

static void init_objgrid(struct sim *sim, struct grid *g, struct obj_def *obj){
	size_t order = GRID_ORDER(obj->resolution);
	size_t vecsize = sizeof(sim_objvec) + VECN(obj->vars)*sizeof(struct tvec);

	sim_objvec *v = alloca(vecsize);
	v->n_alloc = 0;
	v->n_used = 0;
	v->n_bands = VECN(obj->vars);

	for(lexid i=0;i<VECN(obj->vars);i++){
		struct var_def *var = &VECE(obj->vars, i);
		struct tvec *band = &v->bands[i];
		band->type = var->type;
		band->stride = tsize(var->type);
		band->data = NULL;
	}

	size_t gsize = grid_data_size(order, vecsize);
	dv("obj grid[%s]: vec size=%zu (%zu bands), resolution=%zu (order %zu) grid size=%zu bytes\n",
			obj->name, vecsize, VECN(obj->vars), obj->resolution, order, gsize);

	void *data = static_malloc(sim, gsize);
	grid_init(g, order, vecsize, data);

	for(gridpos z=0;z<grid_max(order);z++)
		memcpy(grid_data(g, z), v, vecsize);
}

static void init_envs(struct sim *sim, struct lex *lex){
	sim->n_env = VECN(lex->envs);
	sim->envs = static_malloc(sim, sim->n_env * sizeof(*sim->envs));
	for(lexid i=0;i<sim->n_env;i++)
		init_envgrid(sim, &sim->envs[i], &VECE(lex->envs, i));
}

static void init_envgrid(struct sim *sim, struct env *e, struct env_def *def){
	size_t order = GRID_ORDER(def->resolution);
	size_t stride = tsize(def->type);
	size_t gsize = grid_data_size(order, stride);
	// vmath funcions assume we have a multiple of vector size but order-0 grid allocates
	// only 1 element so make sure we have enough
	gsize = ALIGN(gsize, VEC_ALIGN);

	dv("env grid[%s]: stride=%zu resolution=%zu (order %zu) grid size=%zu bytes\n",
			def->name, stride, def->resolution, order, gsize);

	e->type = def->type;
	e->zoom_mask = ~0;
	void *data = static_malloc(sim, gsize);
	grid_init(&e->grid, order, stride, data);
}

static void init_frame(struct sim *sim){
	sim->depth = 0;
	f_enter(TOP(sim));
}

static void create_savepoint(struct sim *sim, save *sp){
	// Note: this method only copies some data pointers, if you actually want to save
	// stuff you need to either switch the data pointer or add the relevant vectors/grids
	// to the save point
	
	// Copy vector headers for each object. The grid headers don't need to be copied
	// because no one should ever change them
	for(size_t i=0;i<sim->n_obj;i++){
		struct grid *g = &sim->objs[i];
		save_copy(sp, g->data, grid_data_size(g->order, g->stride));
	}

	// Env data pointers can be modified so save the grid headers
	save_copy(sp, sim->envs, sim->n_env*sizeof(*sim->envs));
}

static size_t next_cell_allocvs(struct sim *sim, struct grid *g, size_t n, gridpos *pos,
		sim_objref *refs){

	gridpos vcell = grid_zoom_up(*pos, POSITION_ORDER, g->order);

	size_t nv = 1;
	// TODO this scan loop can be vectorized :>
	while(grid_zoom_up(pos[nv], POSITION_ORDER, g->order) == vcell && nv<n)
		nv++;

	sim_objvec *v = grid_data(g, vcell);
	size_t vpos = v_alloc(sim, v, nv);
	void *varp = tvec_varp(&v->bands[VARID_POSITION], vpos);
	memcpy(varp, pos, nv*sizeof(gridpos));

	for(size_t i=0;i<nv;i++){
		refs[i].vec = v;
		refs[i].idx = vpos+i;
	}

	// TODO: could do some init here eg. zeroing/setting default values

	return nv;
}

static size_t next_cell_deletevs(struct sim *sim, struct grid *g, size_t n, sim_objref *refs){
	// There are a few possibilities for implementing deletion:
	// (a) mark objects "dead" in a bitmap
	//   + fast and simple
	//   - requires an extra bitmap per vector
	//   - alloc is more complicated
	//   - more useless copying when saving branch state
	//   - requires skipping dead elements when iterating (really bad for simd operations)
	// (b) move live objects over dead spots
	//   + no extra bookkeeping
	//   + keeps arrays sequential - no worrying about dead elements in between
	//   + allocation is fast and simple
	//   - requires moving each band if not deleting list tail
	// (c) bucket arrays (aka unrolled linked list)
	//   * this was the first version implemented
	//   + fast and simple allocation and deallocation
	//   - extra rituals when iterating/copying
	//   - no sequential vectors (this also causes extra rituals in the lua side)
	//
	// Since deallocation is rarer than allocation, since allocations naturally die when
	// the branch exits, deletion is done using algorithm (b) in two steps:
	//
	// (1) precalculate needed memcpy indices (move from list tail to deletion pos)
	// (2) replay on all bands

	sim_objvec *v = refs[0].vec;
	size_t run_start[n];
	size_t run_end[n];
	run_start[0] = refs[0].idx;
	size_t nr = 0, rlen = 1;
	size_t nd = 1;

	for(;nd<n&&refs[nd].vec==v;nd++){
		if(refs[nd].idx == run_start[nr]+rlen){
			rlen++;
			continue;
		}

		run_end[nr] = run_start[nr] + rlen;
		nr++;
		run_start[nr] = refs[nd].idx;
		rlen = 1;
	}

	assert(nd <= v->n_used);

	run_end[nr] = run_start[nr] + rlen;
	nr++;

	dv("%zu runs to delete\n", nr);
	for(size_t i=0;i<nr;i++)
		dv("\t[%zu]: %zu - %zu (%zu elements)\n",
				i, run_start[i], run_end[i], run_end[i]-run_start[i]);

	size_t move_dst[nr];
	size_t move_src[nr];
	size_t move_num[nr];

	size_t nmv = 0;
	size_t run = 0, tail_run = nr-1;
	size_t ptr = run_start[0], tail = v->n_used;

	// doesn't matter if tail_run underflows here, since in that case the while loop
	// will never run
	if(tail == run_end[tail_run])
		tail = run_start[tail_run--];

	// (1)
	while(run_end[run] < tail){
		assert(nmv < nr);

		size_t need = run_end[run] - ptr;
		size_t avail = tail - run_end[tail_run];
		size_t num = avail < need ? avail : need;

		move_dst[nmv] = ptr;
		move_src[nmv] = tail - num;
		move_num[nmv] = num;
		/*
		dv("%zu->%zu (%zu) ptr=%zu tail=%zu need=%zu avail=%zu\n",
				move_src[nmv], move_dst[nmv], num, ptr, tail, need, avail);
		*/
		nmv++;

		assert(ptr+num <= run_end[run]);
		assert(tail-num >= run_end[tail_run]);

		if(ptr+num == run_end[run]){
			if(++run == nr)
				break;
			ptr = run_start[run];
		}else{
			ptr += num;
		}

		if(tail-num == run_end[tail_run]){
			assert(tail_run > 0);
			tail = run_start[tail_run--];
		}else{
			tail -= num;
		}
	}

	dv("deleting with %zu moves\n", nmv);
	for(size_t i=0;i<nmv;i++)
		dv("\t[%zu]: %zu -> %zu (%zu elements)\n", i, move_src[i], move_dst[i], move_num[i]);

	// (2)
	if(nmv){
		for(size_t i=0;i<v->n_bands;i++){
			struct tvec *band = &v->bands[i];
			for(size_t j=0;j<nmv;j++){
				memcpy(
					tvec_varp(band, move_dst[j]),
					tvec_varp(band, move_src[j]),
					band->stride * move_num[j]
				);
			}
		}
	}

	v->n_used -= nd;

	return nd;
}

static void v_ensure_cap(struct sim *sim, sim_objvec *v, size_t n){
	if(v->n_used + n <= v->n_alloc)
		return;

	size_t na = v->n_alloc;
	if(!na)
		na = SIM_INIT_VEC_SIZE;

	while(na < n+v->n_used)
		na <<= 1;

	// frame-alloc new bands, no need to free old ones since they were frame-alloced as well
	// NOTE: this will not work if we some day do interleaved bands!
	for(size_t i=0;i<v->n_bands;i++){
		struct tvec *b = &v->bands[i];
		void *old_data = b->data;
		b->data = f_alloc(TOP(sim), b->stride*na, VEC_ALIGN);
		if(v->n_used)
			memcpy(b->data, old_data, b->stride*v->n_used);
	}

	assert(na == ALIGN(na, VEC_ALIGN));
	v->n_alloc = na;
}

static size_t v_alloc(struct sim *sim, sim_objvec *v, size_t n){
	v_ensure_cap(sim, v, n);
	size_t ret = v->n_used;
	v->n_used += n;
	dv("alloc %zu entries [%zu-%u] on vector %p (%u/%u used)\n",
			n, ret, v->n_used, v, v->n_used, v->n_alloc);
	return ret;
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
	arena_destroy(f->arena);
}

static void f_enter(struct frame *f){
	assert(!f->inside);
	f->inside = 1;
	f->branches = NULL;
	f->save = NULL;

	if(!f->init)
		f_init(f);

	arena_reset(f->arena);
}

static save *f_savepoint(struct frame *f){
	assert(f->inside && !f->save);

	f->save = save_create(f->arena);
	return f->save;
}

static void f_restore(struct frame *f){
	assert(f->inside && f->save);
	save_rollback(f->save);
}

static void f_branch(struct frame *f, size_t n, sim_branchid *ids){
	assert(f->inside && !f->branches);

	f->branches = f_alloc(f, sizeof(*f->branches) + n*sizeof(sim_branchid), alignof(*f->branches));
	f->branches->nb = n;
	f->branches->next = 0;
	memcpy(f->branches->ids, ids, n*sizeof(sim_branchid));
}

static sim_branchid f_next_branch(struct frame *f){
	assert(f->inside && f->branches);

	struct branchinfo *b = f->branches;
	if(b->next < b->nb)
		return b->ids[b->next++];

	return SIM_NO_BRANCH;
}

static void f_exit(struct frame *f){
	assert(f->inside);
	f->inside = 0;
}

static void *f_alloc(struct frame *f, size_t size, size_t align){
	return arena_alloc(f->arena, size, align);
}

static void *static_malloc(struct sim *sim, size_t size){
	return arena_malloc(sim->static_arena, size);
}

static int cmp_gridpos(const void *a, const void *b){
	return *((gridpos *) a) - *((gridpos *) b);
}

static int cmp_objref(const void *a, const void *b){
	const sim_objref *ra = a;
	const sim_objref *rb = b;

	// this should be fine since we don't really care if they are in memory order,
	// just that the ones in the same vector are together
	if(ra->vec != rb->vec)
		return ((intptr_t) ra->vec) - ((intptr_t) rb->vec);

	return ((ssize_t) ra->idx) - ((ssize_t) rb->idx);
}
