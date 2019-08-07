#include "lex.h"
#include "arena.h"
#include "grid.h"
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
	unsigned init   : 1;
	unsigned inside : 1;
	unsigned saved  : 1;
	unsigned fid;
	arena *arena;
	size_t vstack_ptr;
	void *vstack_copy;
	struct branchinfo *branches;
};

struct sim {
	arena *static_arena;

	size_t n_obj;
	sim_obj *objs;
	size_t n_env;
	sim_env *envs;

	unsigned next_fid;
	unsigned depth;
	struct frame fstack[SIM_MAX_DEPTH];
	uint8_t vstack[SIM_VSTACK_SIZE] __attribute__((aligned(VEC_ALIGN)));
};

static void init_objs(struct sim *sim, struct lex *lex);
static void init_objgrid(struct sim *sim, sim_obj *o, struct obj_def *def);
static void init_envs(struct sim *sim, struct lex *lex);
static void init_envgrid(struct sim *sim, sim_env *e, struct env_def *def);
static void init_frame(struct sim *sim);

static void *vstack_alloc(struct sim *sim, size_t sz, size_t align);
static void *static_malloc(struct sim *sim, size_t size);
static size_t next_cell_allocvs(struct sim *sim, sim_objref *refs, sim_objtpl *tpl, size_t n,
		gridpos *pos);
static size_t next_cell_deletevs(struct sim *sim, size_t n, sim_objref *refs);

static void v_check_ref(sim_objref *ref);
static sim_vband *v_check_band(sim_objvec *v, lexid varid);
static void v_clear(struct sim *sim, sim_objvec *v);
static void v_ensure_cap(struct sim *sim, sim_objvec *v, size_t n);
static void v_init(sim_objvec *v, size_t idx, size_t n, tvalue *tpl);
static void v_init_band(sim_vband *band, size_t idx, size_t n, tvalue value);
static size_t v_alloc(struct sim *sim, sim_objvec *v, size_t n, size_t m);
static sim_objvec *v_write(struct sim *sim, sim_obj *obj, gridpos pos);

static void destroy_stack(struct sim *sim);

static void f_init(struct frame *f);
static void f_destroy(struct frame *f);
static void f_enter(struct frame *f, unsigned fid);
static size_t f_salloc(struct frame *f, size_t sz, size_t align);
static void f_branch(struct frame *f, size_t n, sim_branchid *ids);
static sim_branchid f_next_branch(struct frame *f);
static int f_contains(struct frame *f, void *p);
static void f_exit(struct frame *f);
static void *f_alloc(struct frame *f, size_t size, size_t align);

#define TOP(sim) (&((sim)->fstack[(sim)->depth]))
#define PREV(sim) (&((sim)->fstack[({ assert((sim)->depth>0); (sim)->depth-1; })]))
static int cmp_gridpos(const void *a, const void *b);
static int cmp_objref(const void *a, const void *b);

struct sim *sim_create(struct lex *lex){
	arena *static_arena = arena_create(SIM_STATIC_ARENA_SIZE);
	struct sim *sim = arena_alloc(static_arena, sizeof(*sim), alignof(*sim));
	sim->static_arena = static_arena;
	init_frame(sim);
	init_objs(sim, lex);
	init_envs(sim, lex);
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

tvalue sim_env_readpos(sim_env *e, gridpos pos){
	pos = sim_env_posz(e, pos);
	return *((tvalue *) grid_data(&e->grid, pos));
}

sim_obj *sim_get_obj(struct sim *sim, lexid objid){
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

void sim_vb_vcopy(sim_vband *band, size_t idx, tvalue v){
	memcpy(sim_vb_varp(band, idx), &v, 1<<band->stride_bits);
}

void *sim_stride_varp(void *data, unsigned stride_bits, size_t idx){
	return ((char *) data) + (idx<<stride_bits);
}

tvalue sim_obj_read1(sim_objref *ref, lexid varid){
	v_check_ref(ref);
	sim_vband *band = v_check_band(ref->vec, varid);
	return *((tvalue *) sim_vb_varp(band, ref->idx));
}

void sim_obj_write1(sim_objref *ref, lexid varid, tvalue value){
	v_check_ref(ref);
	sim_vband *band = v_check_band(ref->vec, varid);
	sim_vb_vcopy(band, ref->idx, value);
}

size_t sim_tpl_size(sim_obj *obj){
	sim_objvec *v = obj->vtemplate;
	return sizeof(sim_objtpl) + (v->n_bands - BUILTIN_VARS_END) * sizeof(tvalue);
}

void sim_tpl_create(sim_obj *obj, sim_objtpl *tpl){
	// make all defaults in tpl 64-bit values by repeating if they are smaller.
	// this is done so during object creation we don't need to mind the size but can just
	// spay 8 byte values in the allocated vector.
	// this results in simpler code and gcc will vectorize it for us.
	// (this is also what memset does, but we can't use memset since we need to handle
	// 1,2,4 or 8 byte values)

	tpl->obj = obj;
	sim_objvec *v = obj->vtemplate;

	for(lexid i=BUILTIN_VARS_END;i<v->n_bands;i++){
		tvalue *t = &tpl->defaults[SIM_TPL_IDX(i)];
		*t = vbroadcast(*t, v->bands[i].type);
	}
}

void sim_allocv(struct sim *sim, sim_objref *refs, sim_objtpl *tpl, size_t n, gridpos *pos){
	// NOTE: this modifies pos!
	// TODO: a better sort here is a good idea
	qsort(pos, n, sizeof(gridpos), cmp_gridpos);
	sim_allocvs(sim, refs, tpl, n, pos);
}

void sim_allocvs(struct sim *sim, sim_objref *refs, sim_objtpl *tpl, size_t n, gridpos *pos){
	// entries going in the same cell are now guaranteed to be sequential due to Z-ordering
	
	while(n){
		size_t nv = next_cell_allocvs(sim, refs, tpl, n, pos);
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
	struct frame *f = TOP(sim);
	assert(!f->saved);

	if(!f->vstack_copy)
		f->vstack_copy = arena_alloc(sim->static_arena, SIM_VSTACK_SIZE, alignof(sim->vstack));

	memcpy(f->vstack_copy, sim->vstack, f->vstack_ptr);
	f->saved = 1;
}

void sim_restore(struct sim *sim){
	struct frame *f = TOP(sim);
	assert(f->saved);

	memcpy(sim->vstack, f->vstack_copy, f->vstack_ptr);
}

void sim_enter(struct sim *sim){
	// TODO error handling
	assert(sim->depth+1 < SIM_MAX_DEPTH);
	sim->depth++;
	dv("==== [%u] enter frame @ %u ====\n", sim->depth, sim->next_fid);
	TOP(sim)->vstack_ptr = PREV(sim)->vstack_ptr;
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
	// object allocation is done on the static arena because the object header including
	// grid data pointer may not be modified during simulation.
	// the actual object grid data is vstack allocated since it contains objvec pointers
	// that can be modified
	sim->n_obj = VECN(lex->objs);
	sim->objs = static_malloc(sim, sim->n_obj * sizeof(*sim->objs));
	for(lexid i=0;i<sim->n_obj;i++)
		init_objgrid(sim, &sim->objs[i], &VECE(lex->objs, i));
}

static void init_objgrid(struct sim *sim, sim_obj *o, struct obj_def *def){
	size_t order = GRID_ORDER(def->resolution);
	size_t vecsize = sizeof(sim_objvec) + VECN(def->vars)*sizeof(sim_vband);

	sim_objvec *v = static_malloc(sim, vecsize);
	v->n_alloc = 0;
	v->n_used = 0;
	v->n_bands = VECN(def->vars);

	for(lexid i=0;i<v->n_bands;i++){
		struct var_def *var = &VECE(def->vars, i);
		sim_vband *band = &v->bands[i];
		band->type = var->type;
		band->stride_bits = __builtin_ffs(tsize(var->type)) - 1;
		assert(tsize(var->type) == (1ULL<<band->stride_bits));
		band->last_modify = 0;
		band->data = NULL;
	}

	size_t gsize = grid_data_size(order, sizeof(sim_objvec *));
	dv("obj grid[%s]: vec size=%zu (%u bands), resolution=%zu (order %zu) grid size=%zu bytes\n",
			def->name, vecsize, v->n_bands, def->resolution, order, gsize);

	o->vsize = vecsize;
	o->vtemplate = v;
	void *data = vstack_alloc(sim, gsize, alignof(sim_objvec *));
	grid_init(&o->grid, order, sizeof(sim_objvec *), data);
	memset(data, 0, gsize);
}

static void init_envs(struct sim *sim, struct lex *lex){
	// env headers are allocated on vstack and initial env grid data on static arena
	// (opposite of obj allocation), since env headers including grid data pointer may
	// be modified, but the actual grid data may not.
	// env updating is done by allocating new grid data then swapping the data pointer,
	// similar to how updating objvecs works.
	sim->n_env = VECN(lex->envs);
	sim->envs = vstack_alloc(sim, sim->n_env*sizeof(*sim->envs), alignof(*sim->envs));
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
	e->zoom_order = 0;
	e->zoom_mask = ~0;
	void *data = static_malloc(sim, gsize);
	grid_init(&e->grid, order, stride, data);
}

static void init_frame(struct sim *sim){
	sim->next_fid = 1;
	sim->depth = 0;
	TOP(sim)->vstack_ptr = 0;
	dv("==== [%u] enter root frame @ %u ====\n", sim->depth, sim->next_fid);
	f_enter(TOP(sim), sim->next_fid++);
}

static void *vstack_alloc(struct sim *sim, size_t sz, size_t align){
	size_t p = f_salloc(TOP(sim), sz, align);
	return &sim->vstack[p];
}

static void *static_malloc(struct sim *sim, size_t size){
	return arena_malloc(sim->static_arena, size);
}

static size_t next_cell_allocvs(struct sim *sim, sim_objref *refs, sim_objtpl *tpl, size_t n,
		gridpos *pos){

	sim_obj *obj = tpl->obj;
	size_t gorder = obj->grid.order;
	gridpos vcell = grid_zoom_up(*pos, POSITION_ORDER, gorder);

	size_t nv = 1;
	// TODO this scan loop can be vectorized :>
	while(grid_zoom_up(pos[nv], POSITION_ORDER, gorder) == vcell && nv<n)
		nv++;

	sim_objvec *v = v_write(sim, obj, vcell);
	// ensure we have enough space to handle the initialization
	// so we don't need to care about overruning the vector in the init code
	size_t vpos = v_alloc(sim, v, nv, ALIGN(nv, sizeof(tvalue)));
	v_init(v, vpos, nv, tpl->defaults);
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

static void v_init(sim_objvec *v, size_t idx, size_t n, tvalue *tpl){
	for(lexid i=BUILTIN_VARS_END;i<v->n_bands;i++)
		v_init_band(&v->bands[i], idx, n, tpl[SIM_TPL_IDX(i)]);
}

static void v_init_band(sim_vband *band, size_t idx, size_t n, tvalue value){
	// init the interval from n to n+idx in band with the requested value.
	// we can't use memset here because we need to handle values larger than 1 byte.
	// on the other hand we can make some assumptions memset can't:
	//   * data pointer is aligned on the size of the value to write
	//   * we can overrun n up to the next alignment to sizeof(tvalue) (ie. 8),
	//     since the caller helpfully made sure that memory is available to use
	//   * our value parameter contains the value we want, extended to 64 bits by repeating
	// This means that after we get the data pointer aligned to 8, we can just spray the
	// 64 bit value without worries :>
	// memset (non-asm version) for reference:
	// https://github.com/lattera/glibc/blob/master/string/memset.c

	size_t sb = band->stride_bits;
	n <<= sb;
	uintptr_t data = (uintptr_t) band->data;
	data += idx << sb;
	uintptr_t end = data + n;

	// align data to 8, this loop works because data is aligned to 1,2,4 or 8 and
	// the value in val is repeated accordingly, so we don't copy anything stupid here
	// another way to this is in 3 steps: first align to 2, then 4 and finally 8,
	// this is probably faster because most allocations will be aligned to 8 bytes anyway
	uint64_t val = value.b64;
	while(data%8){
		*((uint8_t *) data) = val & 0xff;
		val >>= 8;
		data++;
	}

	// now we can spray our value all we want
	// this could probably be vectorized but generally allocations probably aren't
	// large enough to benefit much from that
	for(;data<end;data+=8)
		*((uint64_t *) data) = value.b64;
}

static size_t v_alloc(struct sim *sim, sim_objvec *v, size_t n, size_t m){
	// alloc n entries but ensure we have space for at least m
	// this is done because the object allocator will not init the objects (at most) 8 bytes
	// at a time, so we need to be careful not to overwrite something important
	v_ensure_cap(sim, v, m);
	size_t ret = v->n_used;
	v->n_used += n;
	dv("alloc %zu entries [%zu-%u] on vector %p (%u/%u used)\n",
			n, ret, v->n_used, v, v->n_used, v->n_alloc);
	return ret;
}

static sim_objvec *v_write(struct sim *sim, sim_obj *obj, gridpos pos){
	sim_objvec **vp = grid_data(&obj->grid, pos);
	if(*vp)
		return *vp;

	sim_objvec *v = vstack_alloc(sim, obj->vsize, alignof(*v));
	*vp = v;
	memcpy(v, obj->vtemplate, obj->vsize);
	return v;
}

static void destroy_stack(struct sim *sim){
	for(int i=0;i<SIM_MAX_DEPTH;i++){
		if(sim->fstack[i].init)
			f_destroy(&sim->fstack[i]);
	}
}

static void f_init(struct frame *f){
	assert(!f->init);
	f->init = 1;
	f->arena = arena_create(SIM_ARENA_SIZE);
	f->vstack_copy = NULL;
}

static void f_destroy(struct frame *f){
	assert(f->init);
	arena_destroy(f->arena);
}

static void f_enter(struct frame *f, unsigned fid){
	assert(!f->inside);
	f->fid = fid;
	f->inside = 1;
	f->saved = 0;
	f->branches = NULL;

	if(!f->init)
		f_init(f);

	arena_reset(f->arena);
}

static size_t f_salloc(struct frame *f, size_t sz, size_t align){
	assert(f->inside && !f->saved);

	size_t p = ALIGN(f->vstack_ptr, align);
	f->vstack_ptr = p + sz;
	assert(f->vstack_ptr < SIM_VSTACK_SIZE);
	return p;
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
