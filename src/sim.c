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

struct branchinfo {
	size_t nb;
	size_t next;
	sim_branchid ids[];
};

struct frame {
	unsigned init : 1;
	unsigned inside : 1; /* debug */
	unsigned fid;
	arena *arena;
	save *save;
	struct branchinfo *branches;
};

struct sim {
	arena *static_arena;

	size_t n_obj;
	struct grid *objs;
	size_t n_env;
	sim_env *envs;

	unsigned next_fid;
	unsigned depth;
	struct frame stack[SIM_MAX_DEPTH];
};

static void init_objs(struct sim *sim, struct lex *lex);
static void init_objgrid(struct sim *sim, struct grid *g, struct obj_def *obj);
static void init_envs(struct sim *sim, struct lex *lex);
static void init_envgrid(struct sim *sim, sim_env *e, struct env_def *def);
static void init_frame(struct sim *sim);

static void create_savepoint(struct sim *sim, save *sp);
static size_t next_cell_allocvs(struct sim *sim, struct grid *g, size_t n, gridpos *pos,
		sim_objref *refs);
static size_t next_cell_deletevs(struct sim *sim, size_t n, sim_objref *refs);

static void v_check_ref(sim_objref *ref);
static sim_vband *v_check_band(sim_objvec *v, lexid varid);
static void v_clear(struct sim *sim, sim_objvec *v);
static void v_ensure_cap(struct sim *sim, sim_objvec *v, size_t n);
static void v_init(sim_objvec *v, size_t idx, size_t n);
static size_t v_alloc(struct sim *sim, sim_objvec *v, size_t n);

static void destroy_stack(struct sim *sim);

static void f_init(struct frame *f);
static void f_destroy(struct frame *f);
static void f_enter(struct frame *f, unsigned fid);
static save *f_savepoint(struct frame *f);
static void f_restore(struct frame *f);
static void f_branch(struct frame *f, size_t n, sim_branchid *ids);
static sim_branchid f_next_branch(struct frame *f);
static int f_contains(struct frame *f, void *p);
static void f_exit(struct frame *f);
static void *f_alloc(struct frame *f, size_t size, size_t align);

#define TOP(sim) (&((sim)->stack[(sim)->depth]))
#define PREV(sim) (&((sim)->stack[({ assert((sim)->depth>0); (sim)->depth-1; })]))
static void *static_malloc(struct sim *sim, size_t size);
static int cmp_gridpos(const void *a, const void *b);
static int cmp_objref(const void *a, const void *b);

struct sim *sim_create(struct lex *lex){
	arena *static_arena = arena_create(SIM_STATIC_ARENA_SIZE);
	struct sim *sim = arena_malloc(static_arena, sizeof(*sim));
	sim->static_arena = static_arena;
	init_objs(sim, lex);
	init_envs(sim, lex);
	init_frame(sim);
	return sim;
}

void sim_destroy(struct sim *sim){
	destroy_stack(sim);
	arena_destroy(sim->static_arena);
}

sim_env *sim_get_env(struct sim *sim, lexid envid){
	assert(envid < sim->n_env);
	return &sim->envs[envid];
}

void sim_env_pvec(struct pvec *v, sim_env *e){
	v->type = e->type;
	v->n = grid_max(e->grid.order);
	v->data = e->grid.data;
}

void sim_env_swap(struct sim *sim, sim_env *e, void *data){
	assert(f_contains(TOP(sim), data));
	e->grid.data = data;
}

size_t sim_env_orderz(sim_env *e){
	return e->zoom_order ? e->zoom_order : e->grid.order;
}

gridpos sim_env_posz(sim_env *e, gridpos pos){
	if(e->zoom_order)
		pos = grid_zoom_up(pos & e->zoom_mask, POSITION_ORDER, e->zoom_order);
	else
		pos = grid_zoom_up(pos, POSITION_ORDER, e->grid.order);

	return pos;
}

pvalue sim_env_readpos(sim_env *e, gridpos pos){
	pos = sim_env_posz(e, pos);
	return promote(grid_data(&e->grid, pos), e->type);
}

struct grid *sim_get_objgrid(struct sim *sim, lexid objid){
	assert(objid < sim->n_obj);
	return &sim->objs[objid];
}

void sim_obj_pvec(struct pvec *v, sim_objvec *vec, lexid varid){
	sim_vband *band = v_check_band(vec, varid);
	v->type = band->type;
	v->n = vec->n_used;
	v->data = band->data;
}

void sim_obj_swap(struct sim *sim, sim_objvec *vec, lexid varid, void *data){
	assert(!data || f_contains(TOP(sim), data));
	sim_vband *band = v_check_band(vec, varid);
	band->data = data;
	band->last_modify = TOP(sim)->fid;
}

void *sim_vb_varp(sim_vband *band, size_t idx){
	return sim_stride_varp(band->data, band->stride_bits, idx);
}

void *sim_stride_varp(void *data, unsigned stride_bits, size_t idx){
	return ((char *) data) + (idx<<stride_bits);
}

pvalue sim_obj_read1(sim_objref *ref, lexid varid){
	v_check_ref(ref);
	sim_vband *band = v_check_band(ref->vec, varid);
	return promote(sim_vb_varp(band, ref->idx), band->type);
}

void sim_obj_write1(sim_objref *ref, lexid varid, pvalue value){
	v_check_ref(ref);
	sim_vband *band = v_check_band(ref->vec, varid);
	demote(sim_vb_varp(band, ref->idx), band->type, value);
}

void sim_allocv(struct sim *sim, sim_objref *refs, lexid objid, size_t n, gridpos *pos){
	// NOTE: this modifies pos!
	// TODO: a better sort here is a good idea
	qsort(pos, n, sizeof(gridpos), cmp_gridpos);
	sim_allocvs(sim, refs, objid, n, pos);
}

void sim_allocvs(struct sim *sim, sim_objref *refs, lexid objid, size_t n, gridpos *pos){
	// entries going in the same cell are now guaranteed to be sequential due to Z-ordering
	
	struct grid *g = &sim->objs[objid];

	while(n){
		size_t nv = next_cell_allocvs(sim, g, n, pos, refs);
		n -= nv;
		pos += nv;
		refs += nv;
	}
}

void sim_deletev(struct sim *sim, size_t n, sim_objref *refs){
	// same as allocv, a better sort here would be good
	// (though this function is probably called less often since objects can be just left
	// to die with the branch)
	// TODO: the full vector must be saved when calling this so a better implementation
	// would be to copy the remaining data in a new frame allocated vector?
	// Another possibility is to autosave each run+tail in next_cell_deletev
	qsort(refs, n, sizeof(*refs), cmp_objref);
	sim_deletevs(sim, n, refs);
}

void sim_deletevs(struct sim *sim, size_t n, sim_objref *refs){
	while(n){
		size_t nv = next_cell_deletevs(sim, n, refs);
		n -= nv;
		refs += nv;
	}
}

void *sim_frame_alloc(struct sim *sim, size_t sz, size_t align){
	return f_alloc(TOP(sim), sz, align);
}

void *sim_alloc_band(struct sim *sim, sim_objvec *vec, lexid varid){
	sim_vband *band = v_check_band(vec, varid);
	return sim_frame_alloc(sim, vec->n_alloc<<band->stride_bits, VEC_ALIGN);
}

void *sim_alloc_env(struct sim *sim, sim_env *e){
	struct grid *g = &e->grid;
	return sim_frame_alloc(sim, grid_data_size(g->order, g->stride), VEC_ALIGN);
}

void sim_savepoint(struct sim *sim){
	create_savepoint(sim, f_savepoint(TOP(sim)));
}

void sim_restore(struct sim *sim){
	f_restore(TOP(sim));
}

void sim_enter(struct sim *sim){
	// TODO error handling
	assert(sim->depth+1 < SIM_MAX_DEPTH);
	sim->depth++;
	dv("==== [%u] enter frame @ %u ====\n", sim->depth, sim->next_fid);
	f_enter(TOP(sim), sim->next_fid++);
}

void sim_exit(struct sim *sim){
	assert(sim->depth > 0);
	struct frame *f = TOP(sim);
	f_exit(f);
	dv("---- [%u] exit frame @ %u ----\n", sim->depth, f->fid);
	sim->depth--;
}

// Note: after calling this function, the only sim calls to this frame allowed are:
// * calling sim_next_branch() until it returns 0
// * calling sim_exit() to exit the frame
sim_branchid sim_branch(struct sim *sim, size_t n, sim_branchid *branches){
	// TODO: logic concerning replaying simulations or specific branches goes here
	// e.g. when replaying, only use 1 (or m for m<=n) branches
	f_branch(TOP(sim), n, branches);

	// since simulating on this branch is forbidden now, we only need to make a savepoint
	// if there are more than 1 branch (this state will be forgotten anyway by the relevant
	// upper level branch anyway)
	if(n > 1)
		sim_savepoint(sim);

	sim_branchid ret = f_next_branch(TOP(sim));
	if(ret != SIM_NO_BRANCH)
		sim_enter(sim);

	// TODO: forking could go here?
	return ret;
}

sim_branchid sim_next_branch(struct sim *sim){
	sim_branchid ret = f_next_branch(PREV(sim));

	if(ret != SIM_NO_BRANCH){
		sim_exit(sim);
		sim_restore(sim);
		sim_enter(sim);
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
	size_t vecsize = sizeof(sim_objvec) + VECN(obj->vars)*sizeof(sim_vband);

	sim_objvec *v = alloca(vecsize);
	v->n_alloc = 0;
	v->n_used = 0;
	v->n_bands = VECN(obj->vars);

	for(lexid i=0;i<VECN(obj->vars);i++){
		struct var_def *var = &VECE(obj->vars, i);
		sim_vband *band = &v->bands[i];
		band->type = var->type;
		band->stride_bits = __builtin_ffs(tsize(var->type)) - 1;
		assert(tsize(var->type) == (1ULL<<band->stride_bits));
		band->last_modify = 0;
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

static void init_envgrid(struct sim *sim, sim_env *e, struct env_def *def){
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
	sim->next_fid = 1;
	sim->depth = 0;
	dv("==== [%u] enter root frame @ %u ====\n", sim->depth, sim->next_fid);
	f_enter(TOP(sim), sim->next_fid++);
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
	v_init(v, vpos, nv);
	void *varp = sim_vb_varp(&v->bands[VARID_POSITION], vpos);
	memcpy(varp, pos, nv*sizeof(gridpos));

	for(size_t i=0;i<nv;i++){
		refs[i].vec = v;
		refs[i].idx = vpos+i;
	}

	// TODO: could do some init here eg. zeroing/setting default values

	return nv;
}

static size_t next_cell_deletevs(struct sim *sim, size_t n, sim_objref *refs){
	// "delete" objrefs by copying surviving data into new vector
	
	sim_objvec *v = refs[0].vec;
	size_t idx = refs[0].idx;
	size_t cpy_dst[n];
	size_t cpy_src[n];
	size_t cpy_num[n];
	size_t nc = 0, nd = 0;
	size_t cpos = 0;

	if(idx > 0){
		cpy_dst[nc] = 0;
		cpy_src[nc] = 0;
		cpy_num[nc] = idx;
		nc++;
		cpos = idx;
	}

	for(;nd<n&&refs[nd].vec==v;nd++){
		size_t i = refs[nd].idx;
		if(i > idx+1){
			cpy_dst[nc] = cpos;
			cpy_src[nc] = idx+1;
			cpy_num[nc] = i - (idx+1);
			cpos += cpy_num[nc];
			nc++;
		}
		idx = i;
	}

	if(idx+1 < v->n_used){
		cpy_dst[nc] = cpos;
		cpy_src[nc] = idx+1;
		cpy_num[nc] = v->n_used - (idx+1);
		nc++;
	}

	if(nc > 0){
		dv("delete %zu entries by copying %zu runs:\n", nd, nc);
		for(size_t j=0;j<nc;j++)
			dv("* (%zu): %zu-%zu -> %zu-%zu (%zu entries)\n", j,
					cpy_src[j], cpy_src[j]+cpy_num[j],
					cpy_dst[j], cpy_dst[j]+cpy_num[j],
					cpy_num[j]
			);

		for(lexid i=0;i<v->n_bands;i++){
			sim_vband *band = &v->bands[i];
			void *data = sim_alloc_band(sim, v, i);
			for(size_t j=0;j<nc;j++){
				memcpy(
					sim_stride_varp(data, band->stride_bits, cpy_dst[j]),
					sim_stride_varp(band->data, band->stride_bits, cpy_src[j]),
					cpy_num[j]<<band->stride_bits
				);
			}
			sim_obj_swap(sim, v, i, data);
		}
	}else{
		v_clear(sim, v);
	}

	assert(nd <= v->n_used);
	v->n_used -= nd;

	return nd;
}

static void v_check_ref(sim_objref *ref){
	assert(ref->idx < ref->vec->n_used);
}

static sim_vband *v_check_band(sim_objvec *v, lexid varid){
	assert(varid < v->n_bands);
	return &v->bands[varid];
}

static void v_clear(struct sim *sim, sim_objvec *v){
	for(lexid i=0;i<v->n_bands;i++)
		sim_obj_swap(sim, v, i, NULL);
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
		sim_vband *b = &v->bands[i];
		void *old_data = b->data;
		b->data = f_alloc(TOP(sim), na<<b->stride_bits, VEC_ALIGN);
		if(v->n_used)
			memcpy(b->data, old_data, v->n_used<<b->stride_bits);
	}

	assert(na == ALIGN(na, VEC_ALIGN));
	v->n_alloc = na;
}

static void v_init(sim_objvec *v, size_t idx, size_t n){
	for(lexid i=BUILTIN_VARS_END;i<v->n_bands;i++){
		sim_vband *b = &v->bands[i];
		memset(sim_vb_varp(b, idx), 0, n<<b->stride_bits);
	}
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

static void f_enter(struct frame *f, unsigned fid){
	assert(!f->inside);
	f->fid = fid;
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

static int f_contains(struct frame *f, void *p){
	// ONLY for debugging
	return arena_contains(f->arena, p);
}

static void f_exit(struct frame *f){
	assert(f->inside);
	f->inside = 0;
}

static void *f_alloc(struct frame *f, size_t size, size_t align){
	assert(f->inside);
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
