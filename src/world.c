#include "world.h"
#include "grid.h"
#include "lex.h"
#include "sim.h"

#include <stddef.h>
#include <stdalign.h>
#include <string.h>

// "world" implementation: what kind of objects are being simulated.
// this file implements a world consisting of nested 2D grids of env variables and object vectors.
// note that this is intentionally separate from the simulator core to allow different
// kinds of "worlds", for example:
//   * a non-spatial world, like in MELA or SIMO.
//   * a hexagonal-grid world, like in Monsu.
//   * an object vector+adjacency matrix world (ie. not explicit spatial info, but still spatial
//     relation between neighboring objects), useful for spatial stand-level simulation.

#define VEC_ALIGN M2_VECTOR_SIZE
static_assert((WORLD_INIT_VEC_SIZE % VEC_ALIGN) == 0);

struct world {
	sim *sim;

	size_t n_obj;
	w_obj *objs;
	size_t n_env;
	w_env *envs;
};

static void init_objs(struct world *w, struct lex *lex);
static void init_objgrid(struct world *w, w_obj *o, struct obj_def *def);
static void init_envs(struct world *w, struct lex *lex);
static void init_envgrid(struct world *w, w_env *e, struct env_def *def);

static size_t next_cell_allocvs(struct world *w, w_objref *refs, w_objtpl *tpl, size_t n,
		gridpos *pos);
static size_t next_cell_deletevs(struct world *w, size_t n, w_objref *refs);

static void v_check_ref(w_objref *ref);
static w_vband *v_check_band(w_objvec *v, lexid varid);
static void v_clear(struct world *w, w_objvec *v);
static void v_ensure_cap(struct world *w, w_objvec *v, size_t n);
static void v_init(w_objvec *v, size_t idx, size_t n, tvalue *tpl);
static void v_init_band(w_vband *band, size_t idx, size_t n, tvalue value);
static size_t v_alloc(struct world *w, w_objvec *v, size_t n, size_t m);
static w_objvec *v_write(struct world *w, w_obj *obj, gridpos pos);

void *stride_varp(void *data, unsigned stride_bits, size_t idx);
static int cmp_gridpos(const void *a, const void *b);
static int cmp_objref(const void *a, const void *b);

struct world *w_create(sim *sim, struct lex *lex){
	struct world *w = sim_static_malloc(sim, sizeof(*w));
	w->sim = sim;

	init_objs(w, lex);
	init_envs(w, lex);

	return w;
}

void w_destroy(struct world *w){
	(void)w;
}

w_env *w_get_env(struct world *w, lexid envid){
	assert(envid < w->n_env);
	return &w->envs[envid];
}

void w_env_pvec(struct pvec *v, w_env *e){
	v->type = e->type;
	v->n = grid_max(e->grid.order);
	v->data = e->grid.data;
}

void w_env_swap(struct world *w, w_env *e, void *data){
	assert(sim_is_frame_owned(w->sim, data));
	e->grid.data = data;
}

size_t w_env_orderz(w_env *e){
	return e->zoom_order ? e->zoom_order : e->grid.order;
}

gridpos w_env_posz(w_env *e, gridpos pos){
	if(e->zoom_order)
		pos = grid_zoom_up(pos & e->zoom_mask, POSITION_ORDER, e->zoom_order);
	else
		pos = grid_zoom_up(pos, POSITION_ORDER, e->grid.order);

	return pos;
}

tvalue w_env_readpos(w_env *e, gridpos pos){
	pos = w_env_posz(e, pos);
	return *((tvalue *) grid_data(&e->grid, pos));
}

w_obj *w_get_obj(struct world *w, lexid objid){
	assert(objid < w->n_obj);
	return &w->objs[objid];
}

void w_obj_pvec(struct pvec *v, w_objvec *vec, lexid varid){
	w_vband *band = v_check_band(vec, varid);
	v->type = band->type;
	v->n = vec->n_used;
	v->data = band->data;
}

void w_obj_swap(struct world *w, w_objvec *vec, lexid varid, void *data){
	assert(!data || sim_is_frame_owned(w->sim, data));
	w_vband *band = v_check_band(vec, varid);
	band->data = data;
	// TODO: currently last modifying frame ids are tracked in world core to reduce
	// allocations in future, but maybe sim should have a mechanism to track this?
	// eg. sim_mark(&fid), sim_realloc_if_neeeded(fid, ...) ?
	band->last_modify = sim_frame_id(w->sim);
}

void *w_vb_varp(w_vband *band, size_t idx){
	return stride_varp(band->data, band->stride_bits, idx);
}

void w_vb_vcopy(w_vband *band, size_t idx, tvalue v){
	memcpy(w_vb_varp(band, idx), &v, 1<<band->stride_bits);
}

tvalue w_obj_read1(w_objref *ref, lexid varid){
	v_check_ref(ref);
	w_vband *band = v_check_band(ref->vec, varid);
	return *((tvalue *) w_vb_varp(band, ref->idx));
}

void w_obj_write1(w_objref *ref, lexid varid, tvalue value){
	v_check_ref(ref);
	w_vband *band = v_check_band(ref->vec, varid);
	w_vb_vcopy(band, ref->idx, value);
}

size_t w_tpl_size(w_obj *obj){
	w_objvec *v = obj->vtemplate;
	return sizeof(w_objtpl) + (v->n_bands - BUILTIN_VARS_END) * sizeof(tvalue);
}

void w_tpl_create(w_obj *obj, w_objtpl *tpl){
	// make all defaults in tpl 64-bit values by repeating if they are smaller.
	// this is done so during object creation we don't need to mind the size but can just
	// spay 8 byte values in the allocated vector.
	// this results in simpler code and gcc will vectorize it for us.
	// (this is also what memset does, but we can't use memset since we need to handle
	// 1,2,4 or 8 byte values)

	tpl->obj = obj;
	w_objvec *v = obj->vtemplate;

	for(lexid i=BUILTIN_VARS_END;i<v->n_bands;i++){
		tvalue *t = &tpl->defaults[W_TPL_IDX(i)];
		*t = vbroadcast(*t, v->bands[i].type);
	}
}

void w_allocv(struct world *w, w_objref *refs, w_objtpl *tpl, size_t n, gridpos *pos){
	// NOTE: this modifies pos!
	// TODO: a better sort here is a good idea
	qsort(pos, n, sizeof(gridpos), cmp_gridpos);
	w_allocvs(w, refs, tpl, n, pos);
}

void w_allocvs(struct world *w, w_objref *refs, w_objtpl *tpl, size_t n, gridpos *pos){
	// entries going in the same cell are now guaranteed to be sequential due to Z-ordering
	
	while(n){
		size_t nv = next_cell_allocvs(w, refs, tpl, n, pos);
		n -= nv;
		pos += nv;
		refs += nv;
	}
}

void w_deletev(struct world *w, size_t n, w_objref *refs){
	// same as allocv, a better sort here would be good
	// (though this function is probably called less often since objects can be just left
	// to die with the branch)
	// TODO: the full vector must be saved when calling this so a better implementation
	// would be to copy the remaining data in a new frame allocated vector?
	// Another possibility is to autosave each run+tail in next_cell_deletev
	qsort(refs, n, sizeof(*refs), cmp_objref);
	w_deletevs(w, n, refs);
}

void w_deletevs(struct world *w, size_t n, w_objref *refs){
	while(n){
		size_t nv = next_cell_deletevs(w, n, refs);
		n -= nv;
		refs += nv;
	}
}

void *w_alloc_band(struct world *w, w_objvec *vec, lexid varid){
	w_vband *band = v_check_band(vec, varid);
	return sim_frame_alloc(w->sim, vec->n_alloc<<band->stride_bits, VEC_ALIGN);
}

void *sim_alloc_env(struct world *w, w_env *e){
	struct grid *g = &e->grid;
	return sim_frame_alloc(w->sim, grid_data_size(g->order, g->stride), VEC_ALIGN);
}

static void init_objs(struct world *w, struct lex *lex){
	// object allocation is done on the static arena because the object header including
	// grid data pointer may not be modified during simulation.
	// the actual object grid data is vstack allocated since it contains objvec pointers
	// that can be modified
	w->n_obj = VECN(lex->objs);
	w->objs = sim_static_malloc(w->sim, w->n_obj * sizeof(*w->objs));
	for(lexid i=0;i<w->n_obj;i++)
		init_objgrid(w, &w->objs[i], &VECE(lex->objs, i));
}

static void init_objgrid(struct world *w, w_obj *o, struct obj_def *def){
	size_t order = GRID_ORDER(def->resolution);
	size_t vecsize = sizeof(w_objvec) + VECN(def->vars)*sizeof(w_vband);

	w_objvec *v = sim_static_malloc(w->sim, vecsize);
	v->n_alloc = 0;
	v->n_used = 0;
	v->n_bands = VECN(def->vars);

	for(lexid i=0;i<v->n_bands;i++){
		struct var_def *var = &VECE(def->vars, i);
		w_vband *band = &v->bands[i];
		band->type = var->type;
		band->stride_bits = __builtin_ffs(tsize(var->type)) - 1;
		assert(tsize(var->type) == (1ULL<<band->stride_bits));
		band->last_modify = 0;
		band->data = NULL;
	}

	size_t gsize = grid_data_size(order, sizeof(w_objvec *));
	dv("obj grid[%s]: vec size=%zu (%u bands), resolution=%zu (order %zu) grid size=%zu bytes\n",
			def->name, vecsize, v->n_bands, def->resolution, order, gsize);

	o->vsize = vecsize;
	o->vtemplate = v;
	void *data = sim_vstack_alloc(w->sim, gsize, alignof(w_objvec *));
	grid_init(&o->grid, order, sizeof(w_objvec *), data);
	memset(data, 0, gsize);
}

static void init_envs(struct world *w, struct lex *lex){
	// env headers are allocated on vstack and initial env grid data on static arena
	// (opposite of obj allocation), since env headers including grid data pointer may
	// be modified, but the actual grid data may not.
	// env updating is done by allocating new grid data then swapping the data pointer,
	// similar to how updating objvecs works.
	w->n_env = VECN(lex->envs);
	w->envs = sim_vstack_alloc(w->sim, w->n_env*sizeof(*w->envs), alignof(*w->envs));
	for(lexid i=0;i<w->n_env;i++)
		init_envgrid(w, &w->envs[i], &VECE(lex->envs, i));
}

static void init_envgrid(struct world *w, w_env *e, struct env_def *def){
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
	void *data = sim_static_malloc(w->sim, gsize);
	grid_init(&e->grid, order, stride, data);
}

static size_t next_cell_allocvs(struct world *w, w_objref *refs, w_objtpl *tpl, size_t n,
		gridpos *pos){

	w_obj *obj = tpl->obj;
	size_t gorder = obj->grid.order;
	gridpos vcell = grid_zoom_up(*pos, POSITION_ORDER, gorder);

	size_t nv = 1;
	// TODO this scan loop can be vectorized :>
	while(grid_zoom_up(pos[nv], POSITION_ORDER, gorder) == vcell && nv<n)
		nv++;

	w_objvec *v = v_write(w, obj, vcell);
	// ensure we have enough space to handle the initialization
	// so we don't need to care about overruning the vector in the init code
	size_t vpos = v_alloc(w, v, nv, ALIGN(nv, sizeof(tvalue)));
	v_init(v, vpos, nv, tpl->defaults);
	void *varp = w_vb_varp(&v->bands[VARID_POSITION], vpos);
	memcpy(varp, pos, nv*sizeof(gridpos));

	for(size_t i=0;i<nv;i++){
		refs[i].vec = v;
		refs[i].idx = vpos+i;
	}

	// TODO: could do some init here eg. zeroing/setting default values

	return nv;
}

static size_t next_cell_deletevs(struct world *w, size_t n, w_objref *refs){
	// "delete" objrefs by copying surviving data into new vector
	
	w_objvec *v = refs[0].vec;
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
			w_vband *band = &v->bands[i];
			void *data = w_alloc_band(w, v, i);
			for(size_t j=0;j<nc;j++){
				memcpy(
					stride_varp(data, band->stride_bits, cpy_dst[j]),
					stride_varp(band->data, band->stride_bits, cpy_src[j]),
					cpy_num[j]<<band->stride_bits
				);
			}
			w_obj_swap(w, v, i, data);
		}
	}else{
		v_clear(w, v);
	}

	assert(nd <= v->n_used);
	v->n_used -= nd;

	return nd;
}

static void v_check_ref(w_objref *ref){
	assert(ref->idx < ref->vec->n_used);
}

static w_vband *v_check_band(w_objvec *v, lexid varid){
	assert(varid < v->n_bands);
	return &v->bands[varid];
}

static void v_clear(struct world *w, w_objvec *v){
	for(lexid i=0;i<v->n_bands;i++)
		w_obj_swap(w, v, i, NULL);
}

static void v_ensure_cap(struct world *w, w_objvec *v, size_t n){
	if(v->n_used + n <= v->n_alloc)
		return;

	size_t na = v->n_alloc;
	if(!na)
		na = WORLD_INIT_VEC_SIZE;

	while(na < n+v->n_used)
		na <<= 1;

	// frame-alloc new bands, no need to free old ones since they were frame-alloced as well
	// NOTE: this will not work if we some day do interleaved bands!
	for(size_t i=0;i<v->n_bands;i++){
		w_vband *b = &v->bands[i];
		void *old_data = b->data;
		b->data = sim_frame_alloc(w->sim, na<<b->stride_bits, VEC_ALIGN);
		if(v->n_used)
			memcpy(b->data, old_data, v->n_used<<b->stride_bits);
	}

	assert(na == ALIGN(na, VEC_ALIGN));
	v->n_alloc = na;
}

static void v_init(w_objvec *v, size_t idx, size_t n, tvalue *tpl){
	for(lexid i=BUILTIN_VARS_END;i<v->n_bands;i++)
		v_init_band(&v->bands[i], idx, n, tpl[W_TPL_IDX(i)]);
}

static void v_init_band(w_vband *band, size_t idx, size_t n, tvalue value){
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

static size_t v_alloc(struct world *w, w_objvec *v, size_t n, size_t m){
	// alloc n entries but ensure we have space for at least m
	// this is done because the object allocator will not init the objects (at most) 8 bytes
	// at a time, so we need to be careful not to overwrite something important
	v_ensure_cap(w, v, m);
	size_t ret = v->n_used;
	v->n_used += n;
	dv("alloc %zu entries [%zu-%u] on vector %p (%u/%u used)\n",
			n, ret, v->n_used, v, v->n_used, v->n_alloc);
	return ret;
}

static w_objvec *v_write(struct world *w, w_obj *obj, gridpos pos){
	w_objvec **vp = grid_data(&obj->grid, pos);
	if(*vp)
		return *vp;

	w_objvec *v = sim_vstack_alloc(w->sim, obj->vsize, alignof(*v));
	*vp = v;
	memcpy(v, obj->vtemplate, obj->vsize);
	return v;
}

void *stride_varp(void *data, unsigned stride_bits, size_t idx){
	return ((char *) data) + (idx<<stride_bits);
}

static int cmp_gridpos(const void *a, const void *b){
	return *((gridpos *) a) - *((gridpos *) b);
}

static int cmp_objref(const void *a, const void *b){
	const w_objref *ra = a;
	const w_objref *rb = b;

	// this should be fine since we don't really care if they are in memory order,
	// just that the ones in the same vector are together
	if(ra->vec != rb->vec)
		return ((intptr_t) ra->vec) - ((intptr_t) rb->vec);

	return ((ssize_t) ra->idx) - ((ssize_t) rb->idx);
}
