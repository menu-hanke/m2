#include "vgrid.h"
#include "vec.h"
#include "grid.h"
#include "sim.h"
#include "def.h"

#include <stdlib.h>
#include <stddef.h>
#include <string.h>

static int cmp_gridpos(const void *a, const void *b);
static unsigned F_next_cell_alloc(sim *sim, struct vec_slice *s, struct vgrid *g, unsigned n,
		gridpos *z);

struct vgrid *simLV_vgrid_create(sim *sim, size_t order, struct vec_info *info, unsigned z_band,
		int lifetime){

	struct vgrid *vg = sim_alloc(sim, sizeof(*vg), alignof(*vg), lifetime);
	size_t sz = grid_data_size(order, sizeof(struct vec *));
	void *data = sim_vstack_alloc(sim, sz, sizeof(struct vec *));
	memset(vg->grid.data, 0, sz);
	grid_init(&vg->grid, order, sizeof(struct vec *), data);
	vg->z_band = z_band;
	vg->info = info;

	dv("vgrid<%p>: data<%p> zband=%u size=%zu (order=%zu header size=%zu)\n",
			vg, vg->grid.data, z_band, sz, order, VEC_HEADER_SIZE(info));

	return vg;
}

struct vec *simF_vgrid_vec(sim *sim, struct vgrid *vg, gridpos z){
	struct vec **vp = grid_data(&vg->grid, z);
	if(*vp)
		return *vp;

	*vp = simL_vec_create(sim, vg->info, SIM_FRAME);
	return *vp;
}

unsigned simF_vgrid_alloc(sim *sim, struct vec_slice *ret, struct vgrid *vg, unsigned n,
		gridpos *z){

	// NOTE: this modifies z!
	// TODO: a better sort here is a good idea
	qsort(z, n, sizeof(gridpos), cmp_gridpos);
	return simF_vgrid_alloc_s(sim, ret, vg, n, z);
}

unsigned simF_vgrid_alloc_s(sim *sim, struct vec_slice *ret, struct vgrid *vg, unsigned n,
		gridpos *z){
	
	unsigned nret = 0;

	while(n){
		unsigned nv = F_next_cell_alloc(sim, ret, vg, n, z);
		n -= nv;
		z += nv;
		nret++;
		ret++;
	}

	return nret;
}

static unsigned F_next_cell_alloc(sim *sim, struct vec_slice *s, struct vgrid *g, unsigned n,
		gridpos *z){

	size_t gorder = g->grid.order;
	gridpos vcell = grid_zoom_up(*z, GRID_POSITION_ORDER, gorder);

	unsigned nv = 1;
	while(grid_zoom_up(z[nv], GRID_POSITION_ORDER, gorder) == vcell && nv<n)
		nv++;

	struct vec *v = simF_vgrid_vec(sim, g, vcell);
	unsigned vpos = simF_vec_alloc(sim, v, nv);
	memcpy(v->bands[g->z_band] + vpos*sizeof(*z), z, nv*sizeof(*z));

	s->vec = v;
	s->from = vpos;
	s->to = vpos+nv;

	return nv;
}

static int cmp_gridpos(const void *a, const void *b){
	return *((gridpos *) a) - *((gridpos *) b);
}
