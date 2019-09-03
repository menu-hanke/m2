#include "sim.h"
#include "sim_ds.h"
#include "grid.h"
#include "vec.h"
#include "def.h"

#include <stddef.h>
#include <stdbool.h>
#include <stdalign.h>
#include <stdlib.h>
#include <string.h>

#define HEADER_LIFETIME(x) ((x) & 0x3)
#define DATA_LIFETIME(x)   ((x) >> 2)

#define VEC_ALIGN M2_VECTOR_SIZE
static_assert((SIM_INIT_VEC_SIZE % VEC_ALIGN) == 0);

static void fv_ensure_capacity(sim *sim, struct vec *v, size_t n);
static unsigned fg_next_cell_alloc(sim *sim, struct vec_slice *s, struct svgrid *g, unsigned n,
		gridpos *z);
static int cmp_gridpos(const void *a, const void *b);

void *sim_create_data(sim *sim, size_t size, size_t align, int lifetime){
	void *ret = sim_alloc(sim, size, align, lifetime);
	dv("global<%p>: size=%zu life=%#x\n", ret, size, lifetime);
	return ret;
}

struct grid *sim_create_grid(sim *sim, size_t order, size_t size, int lifetime){
	struct grid *ret = sim_alloc(sim, sizeof(*ret), alignof(*ret), HEADER_LIFETIME(lifetime));
	ret->order = order;
	ret->stride = size;

	size_t sz = grid_data_size(order, size);
	int dlt = (lifetime & SIM_DATA_MUTABLE) ? (SIM_FRAME|SIM_MUTABLE) : (lifetime&SIM_FRAME);
	ret->data = sim_alloc(sim, sz, VEC_ALIGN, dlt);

	dv("grid<%p>: data<%p> size=%zu (order=%zu stride=%zu) life=%#x:%#x\n",
			ret, ret->data, sz, order, size, HEADER_LIFETIME(lifetime), dlt);

	return ret;
}

struct svgrid *sim_create_svgrid(sim *sim, size_t order, unsigned z_band, struct vec *tpl){
	unsigned extra = sizeof(struct vec_band) * tpl->n_bands;
	struct svgrid *ret = sim_alloc(sim, sizeof(*ret) + extra, alignof(*ret), 0);
	ret->z_band = z_band;
	memcpy(&ret->tpl, tpl, vec_header_size(tpl->n_bands));

	ret->grid.order = order;
	ret->grid.stride = sizeof(void *);

	size_t sz = grid_data_size(order, sizeof(void *));
	ret->grid.data = sim_alloc(sim, sz, alignof(void *), SIM_FRAME|SIM_MUTABLE);

	dv("svgrid<%p>: data<%p> zband=%u size=%zu (order=%zu header size=%u)\n",
			ret, ret->grid.data, z_band, sz, order, vec_header_size(tpl->n_bands));

	return ret;
}

struct vec *sim_create_vec(sim *sim, struct vec *tpl, int lifetime){
	unsigned size = vec_header_size(tpl->n_bands);
	struct vec *ret = sim_alloc(sim, size, alignof(*ret), lifetime);
	memcpy(ret, tpl, size);
	return ret;
}

unsigned frame_alloc_vec(sim *sim, struct vec *v, unsigned n){
	fv_ensure_capacity(sim, v, n);
	unsigned ret = v->n_used;
	v->n_used += n;
	dv("alloc %u entries [%u-%u] on vector %p (%u/%u used)\n",
			n, ret, v->n_used, v, v->n_used, v->n_alloc);
	return ret;
}

void frame_delete_vec(sim *sim, struct vec *v, unsigned n, unsigned *del){
	if(!n)
		return;

	void *new_data[v->n_bands];
	for(unsigned i=0;i<v->n_bands;i++)
		new_data[i] = frame_create_band(sim, v, i);

	vec_copy_skip(v, new_data, n, del);

	for(unsigned i=0;i<v->n_bands;i++)
		frame_swap_band(sim, v, i, new_data[i]);
}

void frame_clear_vec(sim *sim, struct vec *v){
	for(unsigned i=0;i<v->n_bands;i++)
		frame_swap_band(sim, v, i, NULL);
}

void frame_swap_band(sim *sim, struct vec *v, unsigned band, void *data){
	assert(!data || sim_is_frame_owned(sim, data));
	struct vec_band *b = V_BAND(v, band);
	b->data = data;
	b->tag = sim_frame_id(sim);
}

void frame_swap_grid(sim *sim, struct grid *g, void *data){
	assert(sim_is_frame_owned(sim, data));
	g->data = data;
}

void *frame_create_band(sim *sim, struct vec *v, unsigned band){
	struct vec_band *b = V_BAND(v, band);
	return sim_frame_alloc(sim, v->n_alloc*b->stride, VEC_ALIGN);
}

void *frame_create_grid_data(sim *sim, struct grid *g){
	return sim_frame_alloc(sim, grid_data_size(g->order, g->stride), VEC_ALIGN);
}

struct vec *frame_lazy_svgrid_vec(sim *sim, struct svgrid *g, gridpos z){
	struct vec **vp = grid_data(&g->grid, z);
	if(*vp)
		return *vp;

	*vp = sim_create_vec(sim, &g->tpl, SIM_FRAME);
	return *vp;
}

unsigned frame_alloc_svgrid(sim *sim, struct vec_slice *ret, struct svgrid *g, unsigned n,
		gridpos *z){

	// NOTE: this modifies pos!
	// TODO: a better sort here is a good idea
	qsort(z, n, sizeof(gridpos), cmp_gridpos);
	return frame_alloc_svgrid_s(sim, ret, g, n, z);
}

unsigned frame_alloc_svgrid_s(sim *sim, struct vec_slice *ret, struct svgrid *g, unsigned n,
		gridpos *z){

	unsigned nret = 0;

	while(n){
		size_t nv = fg_next_cell_alloc(sim, ret, g, n, z);
		n -= nv;
		z += nv;
		nret++;
		ret++;
	}

	return nret;
}

static void fv_ensure_capacity(sim *sim, struct vec *v, size_t n){
	if(v->n_used + n <= v->n_alloc)
		return;

	unsigned na = v->n_alloc;
	if(!na)
		na = SIM_INIT_VEC_SIZE;

	while(na < n+v->n_used)
		na <<= 1;

	dv("realloc vector %p grow %u -> %u\n", v, v->n_alloc, na);

	// frame-alloc new bands, no need to free old ones since they were frame-alloced as well
	// NOTE: this will not work if we some day do interleaved bands!
	for(unsigned i=0;i<v->n_bands;i++){
		struct vec_band *b = &v->bands[i];
		void *old_data = b->data;
		b->data = sim_frame_alloc(sim, na*b->stride, VEC_ALIGN);
		if(v->n_used)
			memcpy(b->data, old_data, v->n_used*b->stride);
	}

	assert(na == ALIGN(na, VEC_ALIGN));
	v->n_alloc = na;
}

static unsigned fg_next_cell_alloc(sim *sim, struct vec_slice *s, struct svgrid *g, unsigned n,
		gridpos *z){

	size_t gorder = g->grid.order;
	gridpos vcell = grid_zoom_up(*z, POSITION_ORDER, gorder);

	unsigned nv = 1;
	// TODO this scan loop can be vectorized :>
	while(grid_zoom_up(z[nv], POSITION_ORDER, gorder) == vcell && nv<n)
		nv++;

	struct vec *v = frame_lazy_svgrid_vec(sim, g, vcell);
	unsigned vpos = frame_alloc_vec(sim, v, nv);
	struct vec_band *b = V_BAND(v, g->z_band);
	memcpy(((char *)b->data) + vpos*sizeof(gridpos), z, nv*sizeof(gridpos));

	s->vec = v;
	s->from = vpos;
	s->to = vpos+nv;

	return nv;
}

static int cmp_gridpos(const void *a, const void *b){
	return *((gridpos *) a) - *((gridpos *) b);
}
