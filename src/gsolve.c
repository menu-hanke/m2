#include "gsolve.h"
#include "vec.h"
#include "type.h"
#include "fhk.h"
#include "def.h"

#include <stdlib.h>

#define COENTER(cofp, ...) ({                  \
	struct co_solve_args _arg = __VA_ARGS__;   \
	gctx->arg = &_arg;                         \
	co_reset(gctx, cofp);                      \
	co_resume(gctx);                           \
})

static int solve_vec(struct vec *vec, struct fhk_solver *solver, unsigned *i_bind){
	unsigned n = vec->n_used;

	for(unsigned i=0;i<n;i++){
		dv("solver[%p]: %u/%u\n", vec, (i+1), n);

		*i_bind = i;

		int r = fhk_solver_step(solver, i);
		if(r)
			return r;
	}

	return FHK_OK;
}

static int solve_vec_z(struct vec *vec, struct fhk_solver *solver, gridpos *z_bind,
		unsigned z_band, unsigned *i_bind){

	unsigned n = vec->n_used;
	gridpos *zb = vec->bands[z_band];

	for(unsigned i=0;i<n;i++){
		dv("solver[%p]: %u/%u\n", vec, (i+1), n);

		*i_bind = i;
		*z_bind = *zb++;

		int r = fhk_solver_step(solver, i);
		if(r)
			return r;
	}

	return FHK_OK;
}

#ifdef M2_SOLVER_INTERRUPTS

#include <aco.h>

struct gs_ctx {
	aco_t *main_co;
	aco_t *solver_co;
	aco_share_stack_t *sstk;
	gs_res ir;
	pvalue *iv;
	struct co_solve_args *arg;
};

struct co_solve_args {
	struct fhk_solver *solver;
	unsigned idx;
	struct vec *vec;
	unsigned *i_bind;
	gridpos *z_bind;
	int z_band;
};

static __thread struct gs_ctx *gctx;

struct gs_ctx *gs_create_ctx(){
	aco_runtime_test();
	aco_thread_init(NULL);

	struct gs_ctx *ctx = malloc(sizeof(*ctx));
	ctx->main_co = aco_create(NULL, NULL, 0, NULL, ctx);
	ctx->sstk = aco_share_stack_new(0);
	ctx->solver_co = aco_create(ctx->main_co, ctx->sstk, 0, NULL, ctx);

	return ctx;
}

void gs_destroy_ctx(struct gs_ctx *ctx){
	aco_destroy(ctx->solver_co);
	aco_destroy(ctx->main_co);
	aco_share_stack_destroy(ctx->sstk);
}

void gs_enter(struct gs_ctx *ctx){
	gctx = ctx;
}

void gs_interrupt(gs_res ir){
	struct gs_ctx *ctx = aco_get_arg();
	ctx->ir = ir;
	aco_yield();
}

static gs_res co_resume(struct gs_ctx *ctx){
	aco_resume(ctx->solver_co);
	return ctx->ir;
}

gs_res gs_resume(pvalue iv){
	struct gs_ctx *ctx = aco_get_arg();
	*ctx->iv = iv;
	return co_resume(ctx);
}

int gs_res_virt(void *v, pvalue *p){
	struct gs_ctx *ctx = aco_get_arg();
	ctx->iv = p;
	struct gs_virt *virt = v;
	gs_interrupt(GS_INTERRUPT_VIRT | virt->handle);
	return FHK_OK;
}

// reuse coroutine object to save mallocs (this is a bit hacky)
static void co_reset(struct gs_ctx *ctx, void *fp){
	aco_t *co = ctx->solver_co;
	co->fp = fp;
	co->reg[ACO_REG_IDX_RETADDR] = fp;
	co->reg[ACO_REG_IDX_SP] = co->share_stack->align_retptr;
	co->is_end = 0;
}

static void co_solve_step(){
	struct gs_ctx *ctx = aco_get_arg();
	struct co_solve_args *arg = ctx->arg;
	gs_interrupt(GS_RETURN | fhk_solver_step(arg->solver, arg->idx));
}

static void co_solve_vec(){
	struct gs_ctx *ctx = aco_get_arg();
	struct co_solve_args *arg = ctx->arg;
	gs_interrupt(GS_RETURN | solve_vec(arg->vec, arg->solver, arg->i_bind));
}

static void co_solve_vec_z(){
	struct gs_ctx *ctx = aco_get_arg();
	struct co_solve_args *arg = ctx->arg;
	gs_interrupt(GS_RETURN
			| solve_vec_z(arg->vec, arg->solver, arg->z_bind, arg->z_band, arg->i_bind));
}

#endif // M2_SOLVER_INTERRUPTS

// TODO: a small perf improvement could be to run the coro version only if the subgraph
// contains any virtuals (this can be precomputed to gs_virt)

gs_res gs_solve_step(struct fhk_solver *solver, unsigned idx){
#ifdef M2_SOLVER_INTERRUPTS
	return COENTER(&co_solve_step, {.solver=solver, .idx=idx});
#else
	return GS_RETURN | fhk_solver_step(solver, idx);
#endif
}

gs_res gs_solve_vec(struct vec *vec, struct fhk_solver *solver, unsigned *i_bind){
	if(vec->n_used == 0)
		return GS_RETURN | FHK_OK;

#ifdef M2_SOLVER_INTERRUPTS
	return COENTER(&co_solve_vec, {.i_bind=i_bind, .solver=solver, .vec=vec});
#else
	return GS_RETURN | solve_vec(vec, solver i_bind);
#endif
}

gs_res gs_solve_vec_z(struct vec *vec, struct fhk_solver *solver, gridpos *z_bind,
		unsigned z_band, unsigned *i_bind){

	if(vec->n_used == 0)
		return GS_RETURN | FHK_OK;

#ifdef M2_SOLVER_INTERRUPTS
	return COENTER(&co_solve_vec_z, {.i_bind=i_bind, .z_bind=z_bind, .z_band=z_band,
			.solver=solver, .vec=vec});
#else
	return GS_RETURN | solve_vec_z(vec, solver, z_bind, z_band, i_bind);
#endif
}
