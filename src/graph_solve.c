#include "fhk.h"
#include "graph.h"
#include "bitmap.h"
#include "type.h"

#include <stdlib.h>
#include <stdbool.h>
#include <string.h>
#include <assert.h>

#ifdef M2_USE_COROUTINES
#include <aco.h>
#endif

struct fhkG_solver {
	struct fhk_graph *G;
	bm8 *init_v;

	// these are NULL for a non-iter solver
	struct fhkG_map_iter *iter;
	bm8 *reset_v;
	bm8 *reset_m;
	pvalue **res;

#ifdef M2_USE_COROUTINES
	aco_t *co;
	fhkG_solver_res ir;

	pvalue *iv;
#endif

	unsigned nv;
	struct fhk_var *xs[];
};

static fhkG_solver_res solve(struct fhkG_solver *S);

#ifdef M2_USE_COROUTINES

static __thread aco_t *main_co = NULL;

// Note: currently the same stack is shared accross solver coroutines, so libaco will copy
// the stack if a solver calls into another solver.
// Since aren't allowed to call themselves recursively, this copying is redundant.
// A better solution would be to set the stack pointer to the top of the share stack on return,
// but this requires modifying libaco (see aco_resume), so currently we just accept the
// (small) performance impact of the unneeded copying.
static __thread aco_share_stack_t *sstk = NULL;

// reuse coroutine object to save mallocs (this is a bit hacky)
static void co_reset(aco_t *co, void *fp){
	co->fp = fp;
	co->reg[ACO_REG_IDX_RETADDR] = fp;
	co->reg[ACO_REG_IDX_SP] = co->share_stack->align_retptr;
	co->is_end = 0;
}

static void co_exit(){
	aco_t *co = aco_co();

	// don't save our stack, we are done (this is also a bit hacky)
	// we don't call aco_exit instead because we don't want to set is_end etc.
	co->share_stack->owner = NULL;
	co->share_stack->align_validsz = 0;
}

static fhkG_solver_res resume(struct fhkG_solver *S){
	// would be more elegant if interrupt would just write to rax directly,
	// but one extra memory access won't affect performance.
	aco_resume(S->co);
	return S->ir;
}

static void interrupt(fhkG_solver_res ir){
	struct fhkG_solver *S = aco_get_arg();
	S->ir = ir;
	aco_yield();
}

static void co_solve(){
	struct fhkG_solver *S = aco_get_arg();
	fhkG_solver_res r = solve(S);
	co_exit();
	interrupt(r);
}

#endif // M2_USE_COROUTINES

bool fhkG_have_interrupts(){
#ifdef M2_USE_COROUTINES
	return true;
#else
	return false;
#endif
}

void fhkG_interruptV(fhkG_handle handle, pvalue *v){
#ifdef M2_USE_COROUTINES
	struct fhkG_solver *S = aco_get_arg();
	S->iv = v;
	interrupt(FHKG_INTERRUPT_V | handle);
#else
	(void)handle;
	(void)v;
	abort();
#endif
}

struct fhkG_solver *fhkG_solver_create(struct fhk_graph *G, unsigned nv, struct fhk_var **xs,
		bm8 *init_v){
	struct fhkG_solver *S = malloc(sizeof(*S) + nv*sizeof(*xs));
	S->G = G;
	S->iter = NULL;
	S->res = NULL;
	S->init_v = init_v;
	S->nv = nv;
	memcpy(S->xs, xs, nv * sizeof(*xs));

#ifdef M2_USE_COROUTINES
	if(!main_co){
		aco_runtime_test();
		aco_thread_init(NULL);

		main_co = aco_create(NULL, NULL, 0, NULL, NULL);
		sstk = aco_share_stack_new(0);
	}

	S->co = aco_create(main_co, sstk, 0, NULL, S);
#endif

	return S;
}

struct fhkG_solver *fhkG_solver_create_iter(struct fhk_graph *G, unsigned nv, struct fhk_var **xs,
		bm8 *init_v, struct fhkG_map_iter *iter, bm8 *reset_v, bm8 *reset_m){

	struct fhkG_solver *S = fhkG_solver_create(G, nv, xs, init_v);
	S->iter = iter;
	S->res = malloc(nv * sizeof(*S->res));
	fhkG_solver_set_reset(S, reset_v, reset_m);

	return S;
}

void fhkG_solver_destroy(struct fhkG_solver *S){
#ifdef M2_USE_COROUTINES
	aco_destroy(S->co);
#endif

	if(S->res)
		free(S->res);

	free(S);
}

fhkG_solver_res fhkG_solver_solve(struct fhkG_solver *S){
	if(S->iter && !S->iter->begin(S->iter))
		return FHKG_RETURN;

	// TODO: fhkG_may_interrupt()? if not, then don't switch stacks but just call solve directly

#ifdef M2_USE_COROUTINES
	co_reset(S->co, co_solve);
	return resume(S);
#else
	return solve(S);
#endif
}

fhkG_solver_res fhkG_solver_resumeV(struct fhkG_solver *S, pvalue iv){
#ifdef M2_USE_COROUTINES
	*S->iv = iv;
	return resume(S);
#else
	(void)S;
	(void)iv;
	abort();
#endif
}

bool fhkG_solver_is_iter(struct fhkG_solver *S){
	return !!S->iter;
}

void fhkG_solver_set_reset(struct fhkG_solver *S, bm8 *reset_v, bm8 *reset_m){
	assert(fhkG_solver_is_iter(S));
	S->reset_v = reset_v;
	S->reset_m = reset_m;
}

void fhkG_solver_bind(struct fhkG_solver *S, unsigned vidx, pvalue *buf){
	assert(fhkG_solver_is_iter(S));
	S->res[vidx] = buf;
}

pvalue **fhkG_solver_binds(struct fhkG_solver *S){
	assert(fhkG_solver_is_iter(S));
	return S->res;
}

static fhkG_solver_res solve(struct fhkG_solver *S){
	if(S->init_v)
		fhk_init(S->G, S->init_v);

	if(!S->iter)
		return fhk_solve(S->G, S->nv, S->xs);

	// Note: this loop isn't performance sensitive
	// (in the sense that fhk_solve() will take almost all of the exec time),
	// but if the iteration needs to be optimized, it can probably be un-abstracted
	// by removing the begin/next function pointers and replacing them with a counter,
	// since all current data structures iterate roughly that way
	for(unsigned idx=0;;idx++){
		int r = fhk_solve(S->G, S->nv, S->xs);
		if(r)
			return r;

		for(unsigned j=0;j<S->nv;j++)
			S->res[j][idx] = S->xs[j]->value;

		if(!S->iter->next(S->iter))
			return FHKG_RETURN;

		if(S->reset_v)
			fhk_reset_mask(S->G, S->reset_v, S->reset_m);
	}
}
