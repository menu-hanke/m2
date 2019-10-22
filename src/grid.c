#include "grid.h"
#include "sim.h"
#include "def.h"

#include <stdlib.h>
#include <assert.h>

static gridpos scatter(gridcoord x);

size_t grid_data_size(size_t order, size_t stride){
	return stride * grid_max(order);
}

void grid_init(struct grid *g, size_t order, size_t stride, void *data){
	g->order = order;
	g->stride = stride;
	g->data = data;
}

void *grid_data(struct grid *g, gridpos z){
	assert(z < grid_max(g->order));
	return ((char *) g->data) + z*g->stride;
}

gridpos grid_max(size_t order){
	return 1UL << order;
}

gridpos grid_pos(gridcoord x, gridcoord y){
	// Note: this could be implemented with a PDEP instruction on newer intel processors
	return scatter(x) | (scatter(y) << 1);
}

/* return a higher level point z' such that z is inside z' */
gridpos grid_zoom_up(gridpos z, size_t from, size_t to){
	assert(from >= to);
	return z >> (from - to);
}

/* return a lower level point z' such that z' is the first point inside z */
gridpos grid_zoom_down(gridpos z, size_t from, size_t to){
	assert(from <= to);
	return z << (to - from);
}

/* return a mask m such that given a point z of order <from>,
 * the point z&m is of order <to>, or equivalently in order <from>,
 * translated to the origin in the first <from>-<to> orders
 * (ie. the mask clears high bits) */
gridpos grid_translate_mask(size_t from, size_t to){
	assert(from >= to);
	gridpos mask = 1ULL << (from - to);
	mask <<= 1;
	mask = ~(mask - 1);
	return mask;
}

struct grid *simL_grid_create(sim *sim, size_t order, size_t size, int lifetime){
	struct grid *ret = sim_alloc(sim, sizeof(*ret), alignof(*ret), lifetime);
	grid_init(ret, order, size, NULL);

	dv("grid<%p>: size=%zu (order=%zu stride=%zu) life=%#x\n",
			ret, grid_data_size(order, size), order, size, lifetime);

	return ret;
}

void *simL_grid_create_data(sim *sim, struct grid *g, int lifetime){
	return sim_alloc(sim, grid_data_size(g->order, g->stride), M2_VECTOR_SIZE, lifetime);
}

static gridpos scatter(gridcoord x){
	gridpos r = x;
	assert(!(r & ~0xffffffff));
	r = (r | (r << 16)) & 0x0000ffff0000ffff;
	r = (r | (r << 8 )) & 0x00ff00ff00ff00ff;
	r = (r | (r << 4 )) & 0x0f0f0f0f0f0f0f0f;
	r = (r | (r << 2 )) & 0x3333333333333333;
	r = (r | (r << 1 )) & 0x5555555555555555;
	return r;
}
