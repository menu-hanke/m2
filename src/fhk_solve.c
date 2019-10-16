#include "def.h"
#include "fhk.h"

#include <stddef.h>
#include <stdbool.h>
#include <setjmp.h>
#include <math.h>
#include <assert.h>

#define HEAP_SIZE 256

// Note: this should be large enough that that x+EPSILON > x for any cost x we might come across,
// but small enough that it will help stopping the solver early.
// too small values may cause the solver to fail, too large values are ok.
#define EPSILON 0.5

struct heap_ent {
	// Note: we could use the cost bound in struct fhk_var for this, however we prefer to
	// store it here for cache locality in heap operations
	double cost;
	struct fhk_var *var;
};

struct heap {
	size_t end;
	struct heap_ent ent[HEAP_SIZE];
};

struct solver_state {
	unsigned cycle : 1;
	struct heap *heap;
	jmp_buf exc_env;
};

static fhk_v2 mm_bound_cost_entry_v(struct fhk_graph *G, struct fhk_var *y, double beta);
static fhk_v2 mm_bound_cost_comp_v(struct fhk_graph *G, struct fhk_var *y, double beta);
static fhk_v2 mm_bound_cost_v(struct fhk_graph *G, struct fhk_var *y, double beta);
static fhk_v2 mm_bound_cost_m(struct fhk_graph *G, struct fhk_model *m, double beta);
static void mm_solve_chain_v(struct fhk_graph *G, struct fhk_var *y, double beta);
static void mm_solve_chain_m(struct fhk_graph *G, struct fhk_model *m, double beta);
static void mm_solve_value(struct fhk_graph *G, struct fhk_var *y);

static void dj_mark_v(struct fhk_graph *G, struct fhk_var *y);
static void dj_mark_m(struct fhk_graph *G, struct fhk_model *m);
static void dj_visit_v(struct fhk_graph *G, struct fhk_var *y);
static void dj_visit_m(struct fhk_graph *G, struct fhk_model *m);
static double dj_beta_m(struct fhk_graph *G, struct fhk_model *m);
static void dj_offer_v(struct fhk_graph *G, struct fhk_var *y, struct fhk_model *m);
static void dj_solve_heap(struct fhk_graph *G, size_t need);
static void dj_solve_bounded(struct fhk_graph *G, size_t nv, struct fhk_var **ys);

#define HEAP_NEXT(h)   do { assert((h)->end+1 < HEAP_SIZE); ++(h)->end; } while(0)
#define HEAP_COST(ent) (ent).cost
#define HEAP_PTR(ent)  (ent).var->hptr
#define HEAP_PARENT(x) ((x)/2)
#define HEAP_LEFT(x)   ((x)*2)
#define HEAP_RIGHT(x)  ((x)*2+1)
static void heap_add(struct heap *h, struct fhk_var *y, double cost);
static void heap_add_unordered(struct heap *h, struct fhk_var *y, double cost);
static void heapify(struct heap *h);
static unsigned heap_cascade_up(struct heap *h, unsigned x, double cost);
static unsigned heap_cascade_down(struct heap *h, unsigned x, double cost);
static void heap_decr_cost(struct heap *h, unsigned x);
static struct heap_ent heap_extract_min(struct heap *h);

static void exec_chain(struct fhk_graph *G, struct fhk_var *y);
static void resolve_given(struct fhk_graph *G, struct fhk_var *x);
static void resolve_value(struct fhk_graph *G, struct fhk_var *x);
static int check_cst(struct fhk_cst *cst, pvalue v);
static void mmin2(struct fhk_model **m1, struct fhk_model **m2, struct fhk_var *y);
static struct fhk_model *mmin0p(struct fhk_var *y);
static pvalue *return_ptr(struct fhk_model *m, struct fhk_var *v);
static void init_given_cost(struct fhk_graph *G, struct fhk_var *y);

#define STATE()           ((struct solver_state *) (G)->solver_state)
#define CHAINSELECTED(vm) ((vm)->chain_selected || (vm)->given)
#define MIN(b)            ((b)[0])
#define MAX(b)            ((b)[1])
#define CHECKBOUND(b)     assert(MIN(b) <= MAX(b))
#define HASVALUE(b)       (MIN(b) == MAX(b))
#define HASCOST(e)        HASVALUE((e)->cost_bound)
#define COST(e)           ({ assert(HASCOST(e)); MIN((e)->cost_bound); })
#define UNSOLVABLE(e)     ((MIN(e->cost_bound) == INFINITY))
#define VBMAP(y)          (&(G)->v_bitmaps[(y)->idx])
#define MBMAP(m)          (&(G)->m_bitmaps[(m)->idx])
#define MARKED(b)         (b)->mark
#define MARK(b)           MARKED(b) = 1
#define UNMARK(b)         MARKED(b) = 0
#define DESCV(v)          ((G)->debug_desc_var ? (G)->debug_desc_var((v)->udata) : ddescv(v))
#define DESCM(m)          ((G)->debug_desc_model ? (G)->debug_desc_model((m)->udata) : ddescm(m))
#define SWAP(A, B)        do { typeof(A) _t = (A); (A) = (B); (B) = _t; } while(0)

// these are needed if you decide to calculate the bitmap offsets
// static_assert(sizeof(struct fhk_model) == 128);
// static_assert(sizeof(struct fhk_var) == 64);
// #define VBMAP(y) (&(G)->v_bitmaps[(y) - (G)->vars])
// #define MBMAP(m) (&(G)->m_bitmaps[(m) - (G)->models])

// we can't use -ffast-math for the whole solver since the solver algorithm depends on infinities
// working correctly. however disabling -ffinite-math-only for the whole solver blocks some
// optimizations so it's enabled selectively on some utilities where it's safe.
#define FAST_MATH __attribute__((optimize("fast-math")))
#define INLINE __attribute__((always_inline)) inline
#define NOUNROLL __attribute__((optimize("no-unroll-loops", "no-peel-loops")))

#define FAIL(res, m, v)   do { dv("solver: failed: " #res "\n"); fail(G,(res),(m),(v)); } while(0)
static void fail(struct fhk_graph *G, int res, struct fhk_model *m, struct fhk_var *v);

#ifdef DEBUG
static const char *ddescv(struct fhk_var *y);
static const char *ddescm(struct fhk_model *m);
#endif

static double costf(struct fhk_model *m, double S);
static fhk_v2 costfv(struct fhk_model *m, fhk_v2 S);
static double costf_invS(struct fhk_model *m, double cost);
static fhk_v2 costf_invSv(struct fhk_model *m, fhk_v2 cost);
static double max(double a, double b);
static double min(double a, double b);
static fhk_v2 minv(fhk_v2 a, fhk_v2 b);
static fhk_v2 cst_bound(struct fhk_graph *G, struct fhk_model *m);
static fhk_v2 par_bound(struct fhk_model *m);

int fhk_solve(struct fhk_graph *G, size_t nv, struct fhk_var **ys){
	assert(!G->dirty);
	DD(G->dirty = 1);

	struct solver_state s;
	s.cycle = 0;

	if(setjmp(s.exc_env))
		return G->last_error.err;

	G->solver_state = &s;

	for(size_t i=0;i<nv;i++){
		struct fhk_var *y = ys[i];
		fhk_v2 ybound = mm_bound_cost_entry_v(G, y, INFINITY);
		if(UNLIKELY(MIN(ybound) == INFINITY))
			FAIL(FHK_SOLVER_FAILED, NULL, y);
	}

	if(UNLIKELY(s.cycle)){
		dv("Cycle detected, using dijkstra solver\n");
		dj_solve_bounded(G, nv, ys);
	}else{
		for(size_t i=0;i<nv;i++)
			mm_solve_value(G, ys[i]);
	}

	return FHK_OK;
}

static fhk_v2 mm_bound_cost_comp_v(struct fhk_graph *G, struct fhk_var *y, double beta){
	fhk_vbmap *bm = VBMAP(y);

	// we absolutely want to avoid going into mm_bound_cost_v here and paying the function
	// call cost for variables we can easily skip here
	if(LIKELY(bm->given || bm->has_bound)){
		if(UNLIKELY(!bm->has_bound))
			init_given_cost(G, y);

		return y->cost_bound;
	}

	return mm_bound_cost_v(G, y, beta);
}

static fhk_v2 mm_bound_cost_entry_v(struct fhk_graph *G, struct fhk_var *y, double beta){
	// this does the same thing as mm_bound_cost_comp_v, but this is faster for variables that
	// most likely are not given or already bounded (ie. entry variables)
	fhk_vbmap *bm = VBMAP(y);

	if(UNLIKELY(bm->given || bm->has_bound)){
		// who would want to solve a given variable?
		if(UNLIKELY(!bm->has_bound))
			init_given_cost(G, y);

		return y->cost_bound;
	}

	return mm_bound_cost_v(G, y, beta);
}

static fhk_v2 mm_bound_cost_v(struct fhk_graph *G, struct fhk_var *y, double beta){
	fhk_vbmap *bm = VBMAP(y);

	// you should only come here from mm_bound_cost_(entry|comp)_v, or unless you're really sure the
	// cost should be computed
	assert(!bm->given && !bm->has_bound);

	// var cost bounding should never hit a cycle,
	// mm_bound_cost_m checks this flag before calling.
	assert(!MARKED(bm));
	MARK(bm);

	fhk_v2 bound = {INFINITY, INFINITY};

	size_t n_mod = y->n_mod;
	struct fhk_model **ms = y->models;
	for(size_t i=0;i<n_mod;i++){
		fhk_v2 mbound = mm_bound_cost_m(G, ms[i], beta);

		// if we find a better MAX bound, no worth trying anything MIN above that
		beta = max(beta, MAX(mbound));

		// pick minimum for both bounds here:
		// * min will be the bound below which we definitely CAN NOT calculate y
		// * max will be the bound below which we definitely CAN calculate y
		bound = minv(bound, mbound);
	}

	UNMARK(bm);
	CHECKBOUND(bound);

	y->cost_bound = bound;
	bm->has_bound = 1;

	dv("Bounded var %s in [%f, %f]\n", DESCV(y), MIN(bound), MAX(bound));
	return bound;
}

static fhk_v2 mm_bound_cost_m(struct fhk_graph *G, struct fhk_model *m, double beta){
	// Note: on some (rare) weird graphs, this function could be entered recursively via multi
	// return models where a return value causes a cycle.
	// that's not a problem: the solver can't get stuck since it can't enter multiple times
	// via the same variable. it will just cause extra work and may also set the low bound
	// too low, which will cause more extra work when the chain is solved.
	// TODO: should make test case for this.

	if(UNLIKELY(MBMAP(m)->has_bound))
		return m->cost_bound;

	// Note (micro-optimization): this only needs to be recalculated when beta changes,
	// not every time we go here
	double beta_S = costf_invS(m, beta);
	fhk_v2 bound_S = cst_bound(G, m);

	if(MIN(bound_S) >= beta_S){
		dv("%s: beta bound from constraints (%f >= %f)\n", DESCM(m), MIN(bound_S), beta_S);
		goto betabound;
	}

	size_t n_param = m->n_param;
	struct fhk_var **xs = m->params;
	for(size_t i=0;i<n_param;i++){
		struct fhk_var *x = xs[i];

		if(UNLIKELY(MARKED(VBMAP(x)))){
			// Solver will hit a cycle, but don't give up.
			// If another chain will be chosen for x, we may still be able to use
			// this model in the future.
			// We can still get a valid low cost bound for the model.
			STATE()->cycle = 1;
			MAX(bound_S) = INFINITY;
			dv("%s: cycle caused by param: %s\n", DESCM(m), DESCV(x));
			continue;
		}

		fhk_v2 xbound = mm_bound_cost_comp_v(G, x, beta_S - MIN(bound_S));
		bound_S += xbound;

		if(MIN(bound_S) >= beta_S)
			goto betabound;
	}

	m->cost_bound = costfv(m, bound_S);
	MBMAP(m)->has_bound = 1;

	dv("%s: bounded cost in [%f, %f]\n", DESCM(m), MIN(m->cost_bound), MAX(m->cost_bound));

	CHECKBOUND(m->cost_bound);
	assert(beta > MIN(m->cost_bound));

	return m->cost_bound;

betabound:
	MIN(m->cost_bound) = costf(m, MIN(bound_S));
	MAX(m->cost_bound) = INFINITY;
	MBMAP(m)->has_bound = 1;

	dv("%s: cost low bound=%f exceeded beta=%f\n", DESCM(m), MIN(m->cost_bound), beta);
	return m->cost_bound;
}

static void mm_solve_chain_v(struct fhk_graph *G, struct fhk_var *y, double beta){
	fhk_vbmap *bm = VBMAP(y);
	assert(bm->has_bound);

	if(MIN(y->cost_bound) >= beta || CHAINSELECTED(bm))
		return;

	assert(!MARKED(bm));
	DD(MARK(bm));

	assert(y->n_mod >= 1);

	if(y->n_mod == 1){
		struct fhk_model *m = y->models[0];
		mm_solve_chain_m(G, m, beta);

		assert(HASCOST(m) || MIN(m->cost_bound) >= beta);

		y->cost_bound = m->cost_bound;

		if(MIN(m->cost_bound) >= beta){
			dv("%s: only model cost=%f exceeded low bound=%f\n", DESCV(y),MIN(m->cost_bound),beta);
			goto out;
		}

		bm->chain_selected = 1;
		y->model = m;

		dv("%s: selected only model: %s (cost=%f)\n", DESCV(y), DESCM(m), COST(m));
		goto out;
	}

	for(;;){
		struct fhk_model *m1, *m2;
		mmin2(&m1, &m2, y);

		if(MIN(m1->cost_bound) >= beta){
			dv("%s: unable to solve below beta=%f\n", DESCV(y), beta);
			goto out;
		}

		fhk_v2 m2_bound = m2->cost_bound;

		// if the min cost of m1 turns out to be more than m2, we can stop and try m2 next.
		// however, add epsilon here, otherwise the case
		//   MIN(m1->cost_bound) == MIN(m2->cost_bound)
		// would cause the solver to loop infinitely since it exits both immediately
		double beta_chain = min(MIN(m2_bound) + EPSILON, beta);
		mm_solve_chain_m(G, m1, beta_chain);

		if(MAX(m1->cost_bound) < beta_chain){
			// no beta exit: we must have solved it
			assert(HASCOST(m1) && MBMAP(m1)->chain_selected);

			bm->chain_selected = 1;
			y->model = m1;
			y->cost_bound = m1->cost_bound;

			dv("%s: selected model %s with cost %f\n", DESCV(y), DESCM(m1), COST(y));
			goto out;
		}

		// beta exit: either we passed the second candidate min cost or we passed beta.
		// we can still have M1(m1->cost_bound) < MIN(m2_bound) here for small beta
		MIN(y->cost_bound) = min(MIN(m1->cost_bound), MIN(m2_bound));
		// we can't take m2 here: some other model may have a smaller max bound
		MAX(y->cost_bound) = min(MAX(m1->cost_bound), MAX(y->cost_bound));
	}

out:
	DD(UNMARK(bm));
}

static void mm_solve_chain_m(struct fhk_graph *G, struct fhk_model *m, double beta){
	fhk_mbmap *bm = MBMAP(m);
	assert(bm->has_bound);

	if(bm->chain_selected){
		assert(HASCOST(m));
		return;
	}

	if(MIN(m->cost_bound) >= beta)
		return;

	// Note: see comment in mm_bound_cost_m: this doesn't always neeed to be recalculated
	double beta_S = costf_invS(m, beta);
	fhk_v2 bound_Sc = cst_bound(G, m);
	fhk_v2 bound_Sp = par_bound(m);

	size_t n_check = m->n_check;
	struct fhk_check *cs = m->checks;
	for(size_t i=0;i<n_check;i++){
		struct fhk_var *x = cs[i].var;

		if(LIKELY(VBMAP(x)->has_value))
			continue;

		// for constraints, the value matters, not the cost
		// so we actually solve the value here
		mm_solve_value(G, x);

		// recompute full bounds here since other constraints may
		// have been solved as a side-effect of solving x.
		bound_Sc = cst_bound(G, m);

		// constraint_bounds() can trigger calculation of params so we need to recompute bounds
		bound_Sp = par_bound(m);

		if(MIN(bound_Sc + bound_Sp) >= beta_S)
			goto betabound;
	}

	assert(HASVALUE(bound_Sc));

	size_t n_param = m->n_param;
	struct fhk_var **xs = m->params;
	for(size_t i=0;i<n_param;i++){
		struct fhk_var *x = xs[i];

		if(CHAINSELECTED(VBMAP(x)))
			continue;

		bool xhasv = HASVALUE(x->cost_bound);

		// here MIN(bound_Sp - x->cost_bound) == sum(MIN(y->cost_bound) : y != x, y in params)
		// this call will either exit with chain_selected=1 or cost exceeds beta
		mm_solve_chain_v(G, x, beta_S - MIN(bound_Sc + bound_Sp - x->cost_bound));

		// no point recomputing bounds if cost didn't change
		if(xhasv)
			continue;

		// unfortunately here we can't just do bound_Sp += newcost - oldcost, for 2 reasons:
		// * solving the parameter can also trigger other parameters to be solved
		// * if maxcost is inf we get an inf-inf situation
		// so we have to fully recalculate bounds
		bound_Sp = par_bound(m);

		if(MIN(bound_Sc + bound_Sp) >= beta_S)
			goto betabound;

		// didn't jump to betabound so mm_solve_chain_v must have solved the chain
		assert(CHAINSELECTED(VBMAP(x)));
	}

	// we don't need to recalculate the bounds here any more, we only skipped parameters
	// with solved bounds and those can't trigger another parameter (since otherwise they would
	// have a check constraint on it and therefore unsolved bounds).
	assert(HASVALUE(bound_Sp));

	m->cost_bound = costfv(m, bound_Sc + bound_Sp);
	MBMAP(m)->chain_selected = 1;
	dv("%s: solved chain, cost: %f (S=%f+%f)\n", DESCM(m), COST(m), MIN(bound_Sc), MIN(bound_Sp));
	return;

betabound:
	m->cost_bound = costfv(m, bound_Sc + bound_Sp);
	dv("%s: min cost=%f (S=%f+%f) exceeded beta=%f\n",
			DESCM(m),
			MIN(m->cost_bound),
			MIN(bound_Sc), MIN(bound_Sp),
			beta
	);
}

static void mm_solve_value(struct fhk_graph *G, struct fhk_var *y){
	fhk_vbmap *bm = VBMAP(y);
	assert(bm->has_bound);

	if(bm->has_value || UNSOLVABLE(y))
		return;

	mm_solve_chain_v(G, y, INFINITY);
	assert(bm->chain_selected || UNSOLVABLE(y));

	if(!UNSOLVABLE(y))
		resolve_value(G, y);
}

static void dj_mark_v(struct fhk_graph *G, struct fhk_var *y){
	fhk_vbmap *bm = VBMAP(y);
	assert(bm->has_bound);

	if(MARKED(bm))
		return;

	MARK(bm);
	y->hptr = 0;

	if(CHAINSELECTED(bm)){
		dv("Search root: %s (chain cost: %f)\n", DESCV(y), COST(y));
		heap_add_unordered(STATE()->heap, y, COST(y));
		return;
	}

	// special case: if we have 0-parameter models then their parameters can't be marked so
	// the marking will never find them, also causing this variable to be excluded from the search.
	// fix this by adding the best 0-parameter model as a candidate if it exists.
	// this doesn't cause any problems:
	//   * no computed checks allowed on cyclic graphs, so the model is valid and has a known cost
	//   * we continue up the graph so any possible better chain is also found
	struct fhk_model *m0 = mmin0p(y);
	if(m0){
		dv("Search root: %s (0-parameter model: %s cost: %f)\n", DESCV(y), DESCM(m0), COST(m0));

		// bounding phase never selects chain so mark it here. (this is a bit hacky, but the
		// model must have chain selected when y leaves the heap, and this will not cause problems
		// since 0-parameter models will always trivially have "chain" selected).
		MBMAP(m0)->chain_selected = 1;
		y->model = m0;
		heap_add_unordered(STATE()->heap, y, COST(m0));
	}

	double max_cost = MAX(y->cost_bound);
	for(unsigned i=0;i<y->n_mod;i++){
		struct fhk_model *m = y->models[i];

		if(MIN(m->cost_bound) <= max_cost && !UNSOLVABLE(m))
			dj_mark_m(G, m);
	}
}

static void dj_mark_m(struct fhk_graph *G, struct fhk_model *m){
	fhk_mbmap *bm = MBMAP(m);
	assert(bm->has_bound);

	if(MARKED(bm))
		return;

	MARK(bm);

	for(unsigned i=0;i<m->n_param;i++)
		dj_mark_v(G, m->params[i]);
}

static void dj_visit_v(struct fhk_graph *G, struct fhk_var *y){
	fhk_vbmap *bm = VBMAP(y);
	assert(MARKED(bm) && CHAINSELECTED(bm));

	// Note: this is an inefficient way to do the check, ways to optimize this are:
	// * during marking, collect the models in the subgraph to a separate array and iterate
	//   over that
	// * store a count/bitmap of solved parameters per model instead of re-checking all
	
	for(unsigned i=0;i<y->n_fwd;i++){
		struct fhk_model *m = y->fwd_models[i];

		if(!MARKED(MBMAP(m)))
			continue;

		dj_visit_m(G, m);
	}
}

static void dj_visit_m(struct fhk_graph *G, struct fhk_model *m){
	fhk_mbmap *bm = MBMAP(m);
	assert(MARKED(bm) && !bm->chain_selected);

	for(unsigned i=0;i<m->n_param;i++){
		struct fhk_var *x = m->params[i];

		if(!CHAINSELECTED(VBMAP(x)))
			return;
	}

	double beta = dj_beta_m(G, m);
	double beta_S = costf_invS(m, beta);
	fhk_v2 bound_Sc = cst_bound(G, m);
	fhk_v2 bound_Sp = par_bound(m);

	assert(HASVALUE(bound_Sp));

	if(MIN(bound_Sc + bound_Sp) >= beta_S)
		goto betabound;

	for(unsigned i=0;i<m->n_check;i++){
		struct fhk_var *x = m->checks[i].var;

		// only given or parameters are accepted as checks in cyclic subgraphs,
		// so this is ok (we just checked parameters at entry).
		resolve_value(G, x);

		// this also means parameter bounds can't change, however constraint bounds neeed
		// to be recomputed
		bound_Sc = cst_bound(G, m);

		if(MIN(bound_Sc + bound_Sp) >= beta_S)
			goto betabound;
	}

	assert(HASVALUE(bound_Sc));

	m->cost_bound = costfv(m, bound_Sc + bound_Sp);
	bm->chain_selected = 1;
	dv("%s: solved chain, cost: %f (S=%f+%f)\n", DESCM(m), COST(m), MIN(bound_Sc), MIN(bound_Sp));

	for(unsigned i=0;i<m->n_return;i++){
		struct fhk_var *y = m->returns[i];
		fhk_vbmap *vm = VBMAP(y);

		if(MARKED(vm) && !CHAINSELECTED(vm))
			dj_offer_v(G, y, m);
	}

	return;

betabound:
	// unmark for debugging so the assert fails if we ever try to touch this model again
	DD(UNMARK(bm));
	dv("%s: min cost=%f (S=%f+%f) exceeded all existing costs (beta=%f)\n",
			DESCM(m),
			costf(m, MIN(bound_Sc + bound_Sp)),
			MIN(bound_Sc),
			MIN(bound_Sp),
			beta
	);
}

static double dj_beta_m(struct fhk_graph *G, struct fhk_model *m){
	// max cost this model can have to be accepted in the solution, ie.
	// max(selected chain cost) over return vars, or infinity if some return does not
	// already have a candidate chain

	struct heap *h = STATE()->heap;
	double beta = 0;

	for(unsigned i=0;i<m->n_return;i++){
		struct fhk_var *y = m->returns[i];
		fhk_vbmap *bm = VBMAP(y);

		if(CHAINSELECTED(bm))
			continue;

		if(MARKED(bm) && y->hptr>0){
			double cost = h->ent[y->hptr].cost;
			if(cost > beta)
				beta = cost;
			continue;
		}

		return INFINITY;
	}

	return beta;
}

static void dj_offer_v(struct fhk_graph *G, struct fhk_var *y, struct fhk_model *m){
	struct heap *h = STATE()->heap;
	double cost = COST(m);

	if(y->hptr > 0){
		struct heap_ent *ent = &h->ent[y->hptr];
		if(cost >= HEAP_COST(*ent))
			return;

		dv("%s: new candidate: %s -> %s (cost: %f -> %f)\n",
				DESCV(y),
				DESCM(y->model),
				DESCM(m),
				COST(y->model),
				cost
		);

		HEAP_COST(*ent) = cost;
		y->model = m;
		heap_decr_cost(h, y->hptr);
	}else{
		dv("%s: first candidate: %s (cost: %f)\n", DESCV(y), DESCM(m), cost);

		y->model = m;
		heap_add(h, y, cost);
	}
}

static void dj_solve_heap(struct fhk_graph *G, size_t need){
	assert(need > 0);
	struct heap *h = STATE()->heap;

	while(h->end > 0){
		struct heap_ent next = heap_extract_min(h);
		struct fhk_var *x = next.var;

		fhk_vbmap *bm = VBMAP(x);

		// technically non-marked variables can go here from multi-return models
		// where we are asked to solve only a subset of the variables
		if(UNLIKELY(!MARKED(bm)))
			continue;

		if(!CHAINSELECTED(bm)){
			double cost = next.cost;
			assert(cost >= MIN(x->cost_bound) && cost <= MAX(x->cost_bound));
			assert(MBMAP(x->model)->chain_selected && cost == COST(x->model));
			MIN(x->cost_bound) = cost;
			MAX(x->cost_bound) = cost;
			bm->chain_selected = 1;
			dv("%s: selected model %s (cost: %f)\n",
					DESCV(x),
					DESCM(x->model),
					COST(x->model)
			);

			if(bm->target && !--need)
				return;
		}

		dj_visit_v(G, x);
	}

	FAIL(FHK_SOLVER_FAILED, NULL, NULL);
}

static void dj_solve_bounded(struct fhk_graph *G, size_t nv, struct fhk_var **ys){
	size_t nsolved = 0;

	for(size_t i=0;i<nv;i++){
		fhk_vbmap *bm = VBMAP(ys[i]);

		bm->target = 1;
		if(CHAINSELECTED(bm))
			nsolved++;
	}

	if(LIKELY(nsolved < nv)){
		struct heap h;
		h.end = 0;
		STATE()->heap = &h;
		for(size_t i=0;i<nv;i++)
			dj_mark_v(G, ys[i]);
		heapify(&h);

		dj_solve_heap(G, nv - nsolved);
	}

	for(size_t i=0;i<nv;i++){
		fhk_vbmap *bm = VBMAP(ys[i]);
		assert(CHAINSELECTED(bm));
		resolve_value(G, ys[i]);
	}
}

static void heap_add(struct heap *h, struct fhk_var *y, double cost){
	HEAP_NEXT(h);
	unsigned idx = heap_cascade_up(h, h->end, cost);
	HEAP_COST(h->ent[idx]) = cost;
	h->ent[idx].var = y;
	HEAP_PTR(h->ent[idx]) = idx;
}

static void heap_add_unordered(struct heap *h, struct fhk_var *y, double cost){
	HEAP_NEXT(h);
	HEAP_COST(h->ent[h->end]) = cost;
	h->ent[h->end].var = y;
}

static void heapify(struct heap *h){
	for(unsigned i=h->end/2;i>0;i--){
		struct heap_ent ent = h->ent[i];
		unsigned idx = heap_cascade_down(h, i, HEAP_COST(ent));
		h->ent[idx] = ent;
	}
}

static unsigned heap_cascade_up(struct heap *h, unsigned x, double cost){
	unsigned p = HEAP_PARENT(x);

	if(p && HEAP_COST(h->ent[p]) > cost){
		h->ent[x] = h->ent[p];
		HEAP_PTR(h->ent[x]) = x;
		return heap_cascade_up(h, p, cost);
	}

	return x;
}

static unsigned heap_cascade_down(struct heap *h, unsigned x, double cost){
	unsigned l = HEAP_LEFT(x);
	unsigned r = HEAP_RIGHT(x);
	unsigned i = x;
	double c = cost;

	if(l <= h->end && HEAP_COST(h->ent[l]) < c){
		i = l;
		c = HEAP_COST(h->ent[l]);
	}

	if(r <= h->end && HEAP_COST(h->ent[r]) < c)
		i = r;

	if(i != x){
		h->ent[x] = h->ent[i];
		HEAP_PTR(h->ent[x]) = x;
		return heap_cascade_down(h, i, cost);
	}

	return x;
}

static void heap_decr_cost(struct heap *h, unsigned x){
	struct heap_ent ent = h->ent[x];
	x = heap_cascade_up(h, x, ent.cost);
	h->ent[x] = ent;
	HEAP_PTR(h->ent[x]) = x;
}

static struct heap_ent heap_extract_min(struct heap *h){
	assert(h->end > 0);

	struct heap_ent ret = h->ent[1];
	struct heap_ent last = h->ent[h->end];
	unsigned idx = heap_cascade_down(h, 1, HEAP_COST(last));
	h->ent[idx] = last;
	h->end--;

	return ret;
}

NOUNROLL static void exec_chain(struct fhk_graph *G, struct fhk_var *y){
	fhk_vbmap *bm = VBMAP(y);

	assert(bm->chain_selected && !bm->has_value);

	// this can be set here eagerly since a selected chain can't have cycles
	bm->has_value = 1;

	struct fhk_model *m = y->model;
	fhk_mbmap *mm = MBMAP(m);

	if(LIKELY(!mm->has_return)){

		// set this eagerly too, this is ok because no cycles
		mm->has_return = 1;

		size_t n_param = m->n_param;
		struct fhk_var **xs = m->params;
		pvalue args[n_param];

		if(LIKELY(n_param > 0)){

#pragma GCC unroll 0
			for(size_t i=0;i<n_param;i++){
				// this won't cause problems because the selected chain will never have a loop
				// Note: we don't need to check UNSOLVABLE here anymore, if we are here then
				// we must have a finite cost
				assert(!UNSOLVABLE(xs[i]));
				//args[i] = resolve_value(G, xs[i]);
				resolve_value(G, xs[i]);
			}

#pragma GCC unroll 0
			for(size_t i=0;i<n_param;i++)
				args[i] = xs[i]->value;
		}

		int res = G->exec_model(G, m->udata, m->rvals, args);
		if(UNLIKELY(res != FHK_OK))
			FAIL(FHK_MODEL_FAILED, m, NULL);
	}

	y->value = *return_ptr(m, y);
	dv("solved %s -> %f / %#lx\n", DESCV(y), y->value.f64, y->value.u64);
}

static void resolve_given(struct fhk_graph *G, struct fhk_var *x){
	fhk_vbmap *bm = VBMAP(x);

	assert(bm->given && !bm->has_value);

	// same logic here as in exec_chain: if the call fails we are doomed anyway so just
	// optimistically set it here and forget
	bm->has_value = 1;

	int r = G->resolve_var(G, x->udata, &x->value);
	if(UNLIKELY(r != FHK_OK))
		FAIL(FHK_VAR_FAILED, NULL, x);

	dv("virtual %s -> %f / %#lx\n", DESCV(x), x->value.f64, x->value.u64);
}

static void resolve_value(struct fhk_graph *G, struct fhk_var *x){
	fhk_vbmap *bm = VBMAP(x);
	assert(CHAINSELECTED(bm));

	if(bm->has_value)
		return;

	if(bm->given)
		resolve_given(G, x);
	else
		exec_chain(G, x);

	assert(bm->has_value);
}

static int check_cst(struct fhk_cst *cst, pvalue v){
	switch(cst->type){

		case FHK_RIVAL:
			return v.f64 >= cst->rival.min && v.f64 <= cst->rival.max;

		case FHK_BITSET:
			//dv("check bitset b=%#lx mask=0%#lx\n", v.u64, cst->setmask);
			return !!(v.u64 & cst->setmask);
	}

	UNREACHABLE();
}

static void mmin2(struct fhk_model **m1, struct fhk_model **m2, struct fhk_var *y){
	assert(y->n_mod >= 2);

	struct fhk_model **m = y->models;
	double xa = MIN(m[0]->cost_bound);
	double xb = MIN(m[1]->cost_bound);
	unsigned a = xa > xb;
	unsigned b = 1 - a;

	size_t n = y->n_mod;
	for(unsigned i=2;i<n;i++){
		double xc = MIN(m[i]->cost_bound);

		if(xc < xb){
			xb = xc;
			b = i;

			if(xb < xa){
				SWAP(xa, xb);
				SWAP(a, b);
			}
		}
	}

	*m1 = y->models[a];
	*m2 = y->models[b];
}

static struct fhk_model *mmin0p(struct fhk_var *y){
	struct fhk_model **m = y->models;
	struct fhk_model *r = NULL;
	double xr = INFINITY;

	for(unsigned i=0;i<y->n_mod;i++){
		if(LIKELY(m[i]->n_param > 0))
			continue;

		// use COST instead of min_cost here. 0-parameter models can't have parameter cost
		// intervals and any check must be given so we have determined the cost.
		if(COST(m[i]) >= xr)
			continue;

		xr = COST(m[i]);
		r = m[i];
	}

	return r;
}

static pvalue *return_ptr(struct fhk_model *m, struct fhk_var *v){
	// this is an ok way to do it since almost all models will have 1 return
	// and 99.999999999% will have at most 4-5
	assert(m->n_return >= 1);

	if(LIKELY(m->returns[0] == v))
		return &m->rvals[0];

	for(unsigned i=1;i<m->n_return;i++){
		if(m->returns[i] == v)
			return &m->rvals[i];
	}

	UNREACHABLE();
}

static void init_given_cost(struct fhk_graph *G, struct fhk_var *y){
	MIN(y->cost_bound) = 0;
	MAX(y->cost_bound) = 0;
	VBMAP(y)->has_bound = 1;
}

__attribute__((cold, noinline, noreturn))
static void fail(struct fhk_graph *G, int res, struct fhk_model *m, struct fhk_var *v){
	struct fhk_einfo *ei = &G->last_error;
	ei->err = res;
	ei->model = m;
	ei->var = v;
	longjmp(STATE()->exc_env, 1);
}

#ifdef DEBUG

#include <string.h>

static const char *ddescv(struct fhk_var *y){
	static __thread char buf[32];
	sprintf(buf, "Var#%d<%p>", y->idx, y);
	return buf;
}

static const char *ddescm(struct fhk_model *m){
	static __thread char buf[32];
	sprintf(buf, "Model#%d<%p>", m->idx, m);
	return buf;
}

#endif

INLINE FAST_MATH static double costf(struct fhk_model *m, double S){
	return m->k[0] + m->c[0]*S;
}

INLINE FAST_MATH static fhk_v2 costfv(struct fhk_model *m, fhk_v2 S){
	return m->k + m->c*S;
}

INLINE FAST_MATH static double costf_invS(struct fhk_model *m, double cost){
	return m->ki[0] + m->ci[0]*cost;
}

INLINE FAST_MATH static fhk_v2 costf_invSv(struct fhk_model *m, fhk_v2 cost){
	return m->ki + m->ci*cost;
}

INLINE FAST_MATH static double max(double a, double b){
	return a > b ? a : b;
}

INLINE FAST_MATH static double min(double a, double b){
	return -max(-a, -b);
}

#ifdef __SSE2__

#include <x86intrin.h>

INLINE FAST_MATH static fhk_v2 minv(fhk_v2 a, fhk_v2 b){
	return _mm_min_pd(a, b);
}

#else 

// gcc doesn't compile this into vminpd...
// (clang does)
INLINE FAST_MATH static fhk_v2 minv(fhk_v2 a, fhk_v2 b){
	fhk_v2 c;
	c[0] = min(a[0], b[0]);
	c[1] = min(a[1], b[1]);
	return c;
}

#endif

// not sure if it makes sense to always inline this
INLINE FAST_MATH NOUNROLL static fhk_v2 cst_bound(struct fhk_graph *G, struct fhk_model *m){
	fhk_v2 ret = {0, 0};

	size_t n_check = m->n_check;
	struct fhk_check *cs = m->checks;

#pragma GCC unroll 0
	for(size_t i=0;i<n_check;i++){
		struct fhk_check *c = &cs[i];
		struct fhk_var *x = c->var;

		fhk_vbmap *bm = VBMAP(x);
		if(UNLIKELY(bm->given && !bm->has_value))
			resolve_given(G, x);

		// Note: c->costs can (and often will) contain infs here,
		// but that shouldn't cause any problems with just some additions
		if(bm->has_value)
			ret += c->cost[!check_cst(&c->cst, x->value)];
		else
			ret += c->cost; // ret += {out, in}
	}

	CHECKBOUND(ret);
	return ret;
}

INLINE FAST_MATH NOUNROLL static fhk_v2 par_bound(struct fhk_model *m){
	size_t n = m->n_param;
	struct fhk_var **xs = m->params;

	fhk_v2 a = {0, 0};
	fhk_v2 b = {0, 0};

	if(n % 2){
		b = xs[n-1]->cost_bound;
		n--;
	}

	for(; n; n-=2){
		a += m->params[n-1]->cost_bound;
		b += m->params[n-2]->cost_bound;
	}

	CHECKBOUND(a + b);
	return a + b;
}
