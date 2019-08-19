#include "world.h"
#include "grid.h"
#include "lex.h"
#include "sim.h"

#include <stddef.h>
#include <stdalign.h>
#include <string.h>

#define VEC_ALIGN M2_VECTOR_SIZE
static_assert((WORLD_INIT_VEC_SIZE % VEC_ALIGN) == 0);

struct world {
	sim *sim;
	// XXX: Maybe keep a list of defined objs here?
	// also obj pools?
};

static size_t next_cell_allocgvs(struct world *w, w_objref *refs, w_objgrid *g, w_objtpl *tpl,
		size_t n, gridpos *pos);
static size_t next_cell_deletegvs(struct world *w, size_t n, w_objref *refs);

static void v_check_ref(w_objref *ref);
static w_vband *v_check_band(w_objvec *v, lexid varid);
static void v_clear(struct world *w, w_objvec *v);
static void v_ensure_cap(struct world *w, w_objvec *v, size_t n);
static void v_init(w_objvec *v, size_t idx, size_t n, tvalue *tpl);
static void v_init_band(w_vband *band, size_t idx, size_t n, tvalue value);
static size_t v_alloc(struct world *w, w_objvec *v, size_t n, size_t m);

void *stride_varp(void *data, unsigned stride_bits, size_t idx);
static int cmp_gridpos(const void *a, const void *b);
static int cmp_objref(const void *a, const void *b);
static int cmp_idx(const void *a, const void *b);

struct world *w_create(sim *sim){
	struct world *w = sim_static_malloc(sim, sizeof(*w));
	w->sim = sim;

	return w;
}

void w_destroy(struct world *w){
	(void)w;
}

w_env *w_define_env(struct world *w, type type, size_t resolution){
	// TODO: env def should have a readonly flag, if set then do static alloc
	w_env *env = sim_alloc(w->sim, sizeof(*env), alignof(*env), SIM_ALLOC_VSTACK);

	env->type = type;
	env->zoom_order = 0;
	env->zoom_mask = ~0;

	size_t order = GRID_ORDER(resolution);
	size_t stride = tsize(type);
	size_t gsize = grid_data_size(order, stride);

	// vmath funcions assume we have a multiple of vector size but order-0 grid allocates
	// only 1 element so make sure we have enough
	gsize = ALIGN(gsize, VEC_ALIGN);

	dv("env[%p]: stride=%zu resolution=%zu (order %zu) grid size=%zu bytes\n",
			env, stride, resolution, order, gsize);

	void *data = sim_alloc(w->sim, gsize, VEC_ALIGN, SIM_ALLOC_STATIC);
	grid_init(&env->grid, order, stride, data);

	return env;
}

w_global *w_define_global(struct world *w, type type){
	// TODO: also put a readonly flag here
	// (is the type needed or could we just alloc a tvalue?)
	w_global *glob = sim_alloc(w->sim, sizeof(*glob), alignof(*glob), SIM_ALLOC_VSTACK);
	glob->type = type;

	dv("global[%p]: type=%d\n", glob, type);

	return glob;
}

w_obj *w_define_obj(struct world *w, size_t nv, type *vtypes){
	size_t vecsize = sizeof(w_objvec) + nv*sizeof(w_vband);
	w_obj *obj = sim_alloc(w->sim, sizeof(*obj) + vecsize, alignof(*obj), SIM_ALLOC_STATIC);
	obj->z_band = -1;
	obj->vsize = vecsize;

	w_objvec *tpl = &obj->vtemplate;
	tpl->n_alloc = 0;
	tpl->n_used = 0;
	tpl->n_bands = nv;

	for(lexid i=0;i<tpl->n_bands;i++){
		w_vband *band = &tpl->bands[i];
		band->type = vtypes[i];
		band->stride_bits = __builtin_ffs(tsize(vtypes[i])) - 1;
		assert(tsize(vtypes[i]) == (1ULL<<band->stride_bits));
		band->last_modify = 0;
		band->data = NULL;
	}

	dv("obj[%p]: vec size=%zu (%u bands)\n", obj, vecsize, tpl->n_bands);

	return obj;
}

w_objgrid *w_define_objgrid(struct world *w, w_obj *obj, size_t order){
	assert(W_ISSPATIAL(obj));

	w_objgrid *g = sim_alloc(w->sim, sizeof(*g), alignof(*g), SIM_ALLOC_STATIC);
	g->obj = obj;

	size_t gsize = grid_data_size(order, sizeof(w_objvec *));
	dv("objgrid[%p]: %p order=%zu grid size=%zu\n",
			obj, g, order, gsize);

	void *data = sim_alloc(w->sim, gsize, alignof(w_objvec *), SIM_ALLOC_VSTACK);
	grid_init(&g->grid, order, sizeof(w_objvec *), data);
	memset(data, 0, gsize);

	return g;
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
	return sizeof(w_objtpl) + obj->vtemplate.n_bands * sizeof(tvalue);
}

void w_tpl_create(w_obj *obj, w_objtpl *tpl){
	// make all defaults in tpl 64-bit values by repeating if they are smaller.
	// this is done so during object creation we don't need to mind the size but can just
	// spay 8 byte values in the allocated vector.
	// this results in simpler code and gcc will vectorize it for us.
	// (this is also what memset does, but we can't use memset since we need to handle
	// 1,2,4 or 8 byte values)

	w_objvec *v = &obj->vtemplate;

	for(lexid i=0;i<v->n_bands;i++){
		tvalue *t = &tpl->defaults[i];
		*t = vbroadcast(*t, v->bands[i].type);
	}
}

void *w_env_create_data(struct world *w, w_env *e){
	struct grid *g = &e->grid;
	return sim_alloc(w->sim, grid_data_size(g->order, g->stride), VEC_ALIGN, SIM_ALLOC_FRAME);
}

w_objvec *w_obj_create_vec(struct world *w, w_obj *obj){
	w_objvec *v = sim_alloc(w->sim, obj->vsize, alignof(*v), SIM_ALLOC_VSTACK);
	memcpy(v, &obj->vtemplate, obj->vsize);
	return v;
}

size_t w_objvec_alloc(struct world *w, w_objvec *vec, w_objtpl *tpl, size_t n){
	size_t vpos = v_alloc(w, vec, n, ALIGN(n, sizeof(tvalue)));
	v_init(vec, vpos, n, tpl->defaults);
	return vpos;
}

size_t w_objvec_delete(struct world *w, w_objvec *vec, size_t n, size_t *del){
	qsort(del, n, sizeof(size_t), cmp_idx);
	return w_objvec_delete_s(w, vec, n, del);
}

size_t w_objvec_delete_s(struct world *w, w_objvec *v, size_t n, size_t *del){
	// "delete" objrefs by copying surviving data into new vector
	
	size_t cpy_dst[n];
	size_t cpy_src[n];
	size_t cpy_num[n];

	size_t next = 0, cpos = 0, nc = 0;

	for(size_t i=0;i<n;i++){
		size_t d = del[i];

		if(d > next){
			cpy_dst[nc] = cpos;
			cpy_src[nc] = next;
			cpy_num[nc] = d - next;
			cpos += cpy_num[nc];
			nc++;
		}

		next = d+1;
	}

	// tail
	if(next < v->n_used){
		cpy_dst[nc] = cpos;
		cpy_src[nc] = next;
		cpy_num[nc] = v->n_used - next;
		cpos += cpy_num[nc];
		nc++;
	}

	assert(cpos <= v->n_used);
	size_t nd = v->n_used - cpos;
	v->n_used -= cpos;
	assert(nd <= n);

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
			void *data = w_objvec_create_band(w, v, i);
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

	return nd;
}

void *w_objvec_create_band(struct world *w, w_objvec *vec, lexid varid){
	w_vband *band = v_check_band(vec, varid);
	return sim_alloc(w->sim, vec->n_alloc<<band->stride_bits, VEC_ALIGN, SIM_ALLOC_FRAME);
}

void w_objgrid_alloc(struct world *w, w_objref *refs, w_objgrid *g, w_objtpl *tpl, size_t n,
		gridpos *pos){

	// NOTE: this modifies pos!
	// TODO: a better sort here is a good idea
	qsort(pos, n, sizeof(gridpos), cmp_gridpos);
	w_objgrid_alloc_s(w, refs, g, tpl, n, pos);
}

void w_objgrid_alloc_s(struct world *w, w_objref *refs, w_objgrid *g, w_objtpl *tpl, size_t n,
		gridpos *pos){

	// entries going in the same cell are now guaranteed to be sequential due to Z-ordering

	while(n){
		size_t nv = next_cell_allocgvs(w, refs, g, tpl, n, pos);
		n -= nv;
		pos += nv;
		refs += nv;
	}
}

void w_objref_delete(struct world *w, size_t n, w_objref *refs){
	qsort(refs, n, sizeof(*refs), cmp_objref);
	w_objref_delete_s(w, n, refs);
}

void w_objref_delete_s(struct world *w, size_t n, w_objref *refs){
	while(n){
		size_t nv = next_cell_deletegvs(w, n, refs);
		n -= nv;
		refs += nv;
	}
}

gridpos w_objgrid_posz(w_objgrid *g, gridpos pos){
	return grid_zoom_up(pos, POSITION_ORDER, g->grid.order);
}

w_objvec *w_objgrid_write(world *w, w_objgrid *g, gridpos z){
	w_objvec **vp = grid_data(&g->grid, z);
	if(*vp)
		return *vp;

	*vp = w_obj_create_vec(w, g->obj);
	return *vp;
}

static size_t next_cell_allocgvs(struct world *w, w_objref *refs, w_objgrid *g, w_objtpl *tpl,
		size_t n, gridpos *pos){

	size_t gorder = g->grid.order;
	gridpos vcell = grid_zoom_up(*pos, POSITION_ORDER, gorder);

	size_t nv = 1;
	// TODO this scan loop can be vectorized :>
	while(grid_zoom_up(pos[nv], POSITION_ORDER, gorder) == vcell && nv<n)
		nv++;

	w_objvec *v = w_objgrid_write(w, g, vcell);
	size_t vpos = w_objvec_alloc(w, v, tpl, nv);
	void *varp = w_vb_varp(&v->bands[g->obj->z_band], vpos);
	memcpy(varp, pos, nv*sizeof(gridpos));

	for(size_t i=0;i<nv;i++){
		refs[i].vec = v;
		refs[i].idx = vpos+i;
	}

	return nv;
}

static size_t next_cell_deletegvs(struct world *w, size_t n, w_objref *refs){
	size_t nv = 1;
	size_t del[n];
	w_objvec *v = refs[0].vec;
	del[0] = refs[0].idx;

	while(refs[nv].vec == v && nv<n){
		del[nv] = refs[nv].idx;
		nv++;
	}

	w_objvec_delete_s(w, v, nv, del);
	return nv;
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
	for(lexid i=0;i<v->n_bands;i++)
		v_init_band(&v->bands[i], idx, n, tpl[i]);
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

static int cmp_idx(const void *a, const void *b){
	return *((size_t *) a) - *((size_t *) b);
}
