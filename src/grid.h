#pragma once

#include "sim.h"

#include <stdlib.h>
#include <stdint.h>

typedef uint64_t gridpos;
typedef uint32_t gridcoord;

/* A square 2D grid with 2^{order} pixels in each dimension stored as a Z-order curve,
 * where order=2*k for some k */
struct grid {
	size_t order;
	size_t stride;
	void *data;
};

#define GRID_INVALID   ((gridpos)(~0))
#define GRID_ORDER(k)  ((k)<<1)
#define GRID_MAX_ORDER GRID_ORDER(31)

enum {
	GRID_POSITION_ORDER = GRID_MAX_ORDER
};

size_t grid_data_size(size_t order, size_t stride);
void grid_init(struct grid *g, size_t order, size_t stride, void *data);
void *grid_data(struct grid *g, gridpos z);

gridpos grid_max(size_t order);
gridpos grid_pos(gridcoord x, gridcoord y);
gridpos grid_zoom_up(gridpos z, size_t from, size_t to);
gridpos grid_zoom_down(gridpos z, size_t from, size_t to);
gridpos grid_translate_mask(size_t from, size_t to);

struct grid *simL_grid_create(sim *sim, size_t order, size_t size, int lifetime);
void *simL_grid_create_data(sim *sim, struct grid *grid, int lifetime);
