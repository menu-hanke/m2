#pragma once

#include "fhk.h"
#include "type.h"
#include "vec.h"
#include "grid.h"
#include "def.h"

#include <stdint.h>

typedef uint32_t gs_res;

enum {
	GS_RETURN         = 0,
	GS_INTERRUPT_VIRT = 1 << 31,
	/* GS_INTERRUPT_MODEL - the same technique can be used to implement models in sim state */
	GS_ARG_MASK       = (1 << 16) - 1
};

#ifdef M2_SOLVER_INTERRUPTS

#include "gmap.h"

typedef struct gs_ctx gs_ctx;

gs_ctx *gs_create_ctx();
void gs_destroy_ctx(gs_ctx *ctx);

void gs_enter(gs_ctx *ctx);
void gs_interrupt(gs_res ir);
gs_res gs_resume1(gs_ctx *ctx, pvalue iv);
gs_res gs_resume0(gs_ctx *ctx);

void gs_intv(uint32_t handle, pvalue *p);

#endif

gs_res gs_solve_step(struct fhk_solver *solver, unsigned idx);
gs_res gs_solve_vec(struct vec *vec, struct fhk_solver *solver, unsigned *i_bind);
gs_res gs_solve_vec_z(struct vec *vec, struct fhk_solver *solver, gridpos *z_bind,
		unsigned z_band, unsigned *i_bind);
