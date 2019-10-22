#pragma once

#include "vec.h"
#include "grid.h"
#include "sim.h"

struct vgrid {
	struct grid grid;
	struct vec_info *info;
	unsigned z_band;
};

struct vgrid *simLV_vgrid_create(sim *sim, size_t order, struct vec_info *info, unsigned z_band,
		int lifetime);
struct vec *simF_vgrid_vec(sim *sim, struct vgrid *vg, gridpos z);
unsigned simF_vgrid_alloc(sim *sim, struct vec_slice *ret, struct vgrid *vg, unsigned n,
		gridpos *z);
unsigned simF_vgrid_alloc_s(sim *sim, struct vec_slice *ret, struct vgrid *vg, unsigned n,
		gridpos *z);
