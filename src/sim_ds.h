#pragma once

/* sim-memory backed data structures */

#include "sim.h"
#include "grid.h"
#include "vec.h"

#include <stdbool.h>
#include <stddef.h>

struct svgrid {
	struct grid grid;
	unsigned z_band;
	struct vec tpl; // must be last
};

enum {
	POSITION_RESOLUTION = 31,
	POSITION_ORDER      = GRID_ORDER(POSITION_RESOLUTION)
};

enum {
	SIM_DATA_MUTABLE = 0x4
};

void *sim_create_data(sim *sim, size_t size, size_t align, int lifetime);
struct grid *sim_create_grid(sim *sim, size_t order, size_t size, int lifetime);
struct svgrid *sim_create_svgrid(sim *sim, size_t order, unsigned z_band, struct vec *tpl);
struct vec *sim_create_vec(sim *sim, struct vec *tpl, int lifetime);

unsigned frame_alloc_vec(sim *sim, struct vec *v, unsigned n);
void frame_delete_vec(sim *sim, struct vec *v, unsigned n, unsigned *del);
void frame_clear_vec(sim *sim, struct vec *v);
void frame_swap_band(sim *sim, struct vec *v, unsigned band, void *data);
void frame_swap_grid(sim *sim, struct grid *g, void *data);
void *frame_create_band(sim *sim, struct vec *v, unsigned band);
void *frame_create_grid_data(sim *sim, struct grid *g);
struct vec *frame_lazy_svgrid_vec(sim *sim, struct svgrid *g, gridpos z);
unsigned frame_alloc_svgrid(sim *sim, struct vec_slice *ret, struct svgrid *g, unsigned n,
		gridpos *z);
unsigned frame_alloc_svgrid_s(sim *sim, struct vec_slice *ret, struct svgrid *g, unsigned n,
		gridpos *z);
