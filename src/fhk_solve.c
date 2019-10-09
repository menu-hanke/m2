#include "def.h"
#include "fhk.h"

#include <stddef.h>
#include <math.h>
#include <setjmp.h>
#include <assert.h>

#define HEAP_SIZE 256

struct heap_ent {
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

static void mm_bound_cost_v(struct fhk_graph *G, struct fhk_var *y, double beta);
static void mm_bound_cost_m(struct fhk_graph *G, struct fhk_model *m, double beta);
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
static void exec_model(struct fhk_graph *G, struct fhk_model *m);

static double costf(struct fhk_model *m, double S);
static double costf_inverse_S(struct fhk_model *m, double cost);
static int check_cst(struct fhk_cst *cst, pvalue v);
static void constraint_bounds(struct fhk_graph *G, double *Sc_min, double *Sc_max,
		struct fhk_model *m);
static void resolve_value(struct fhk_graph *G, struct fhk_var *x);
static void resolve_given(struct fhk_graph *G, struct fhk_var *x);
static void param_bounds(double *Sp_min, double *Sp_max, struct fhk_model *m);
static void mmin2(struct fhk_model **m1, struct fhk_model **m2, struct fhk_var *y);
static struct fhk_model *mmin0p(struct fhk_var *y);
static pvalue *return_ptr(struct fhk_model *m, struct fhk_var *v);

#define STATE()           ((struct solver_state *) (G)->solver_state)
#define COST(e)           ({ assert((e)->min_cost == (e)->max_cost); (e)->min_cost; })
#define ISPINF(x)         (isinf(x) && (x)>0)
#define UNSOLVABLE(e)     ISPINF((e)->min_cost)
#define CHAINSELECTED(vm) ((vm)->chain_selected || (vm)->given)
#define VBMAP(y)          (&(G)->v_bitmaps[(y)->idx])
#define MBMAP(m)          (&(G)->m_bitmaps[(m)->idx])
#define MARKED(b)         (b)->mark
#define MARK(b)           MARKED(b) = 1
#define UNMARK(b)         MARKED(b) = 0
#define DESCV(v)          ((G)->debug_desc_var ? (G)->debug_desc_var((v)->udata) : ddescv(v))
#define DESCM(m)          ((G)->debug_desc_model ? (G)->debug_desc_model((m)->udata) : ddescm(m))
#define FAIL(res, m, v)   do { dv("solver: failed: " #res "\n"); fail(G,(res),(m),(v)); } while(0)
#define SWAP(A, B)        do { typeof(A) _t = (A); (A) = (B); (B) = _t; } while(0)
static void fail(struct fhk_graph *G, int res, struct fhk_model *m, struct fhk_var *v);
#ifdef DEBUG
static const char *ddescv(struct fhk_var *y);
static const char *ddescm(struct fhk_model *m);
#endif

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
		mm_bound_cost_v(G, y, INFINITY);
		if(UNSOLVABLE(y))
			FAIL(FHK_SOLVER_FAILED, NULL, y);
	}

	if(s.cycle){
		dv("Cycle detected, using dijkstra solver\n");
		dj_solve_bounded(G, nv, ys);
	}else{
		for(size_t i=0;i<nv;i++)
			mm_solve_value(G, ys[i]);
	}

	return FHK_OK;
}

static void mm_bound_cost_v(struct fhk_graph *G, struct fhk_var *y, double beta){
	fhk_vbmap *bm = VBMAP(y);

	if(bm->has_bound)
		return;

	if(bm->given){
		y->min_cost = 0;
		y->max_cost = 0;
		bm->has_bound = 1;
		return;
	}

	// var cost bounding should never hit a cycle,
	// mm_bound_cost_m checks this flag before calling.
	assert(!MARKED(bm));

	MARK(bm);

	for(size_t i=0;i<y->n_mod;i++){
		struct fhk_model *m = y->models[i];
		mm_bound_cost_m(G, m, beta);

		if(m->max_cost < beta)
			beta = m->max_cost;
	}

	UNMARK(bm);

	double min = INFINITY, max = INFINITY;

	for(size_t i=0;i<y->n_mod;i++){
		struct fhk_model *m = y->models[i];

		if(m->min_cost < min)
			min = m->min_cost;

		if(m->max_cost < max)
			max = m->max_cost;
	}

	assert(max >= min);

	y->min_cost = min;
	y->max_cost = max;
	bm->has_bound = 1;

	dv("Bounded var %s in [%f, %f]\n", DESCV(y), min, max);
}

static void mm_bound_cost_m(struct fhk_graph *G, struct fhk_model *m, double beta){
	if(MBMAP(m)->has_bound)
		return;

	double beta_S = costf_inverse_S(m, beta);

	double S_min, S_max;
	constraint_bounds(G, &S_min, &S_max, m);

	if(S_min >= beta_S){
		dv("%s: beta bound from constraints (%f >= %f)\n", DESCM(m), S_min, beta_S);
		goto betabound;
	}

	for(size_t i=0;i<m->n_param;i++){
		struct fhk_var *x = m->params[i];

		if(MARKED(VBMAP(x))){
			// Solver will hit a cycle, but don't give up.
			// If another chain will be chosen for x, we may still be able to use
			// this model in the future.
			// We can still get a valid low cost bound for the model.
			STATE()->cycle = 1;
			S_max = INFINITY;
			dv("%s: cycle caused by param: %s\n", DESCM(m), DESCV(x));
			continue;
		}

		mm_bound_cost_v(G, x, beta_S - S_min);

		S_min += x->min_cost;
		S_max += x->max_cost;

		if(S_min >= beta_S)
			goto betabound;
	}

	m->min_cost = costf(m, S_min);
	m->max_cost = costf(m, S_max);
	MBMAP(m)->has_bound = 1;

	dv("%s: bounded cost in [%f, %f]\n", DESCM(m), m->min_cost, m->max_cost);

	assert(m->max_cost >= m->min_cost);
	assert(beta > m->min_cost);

	return;

betabound:
	m->min_cost = costf(m, S_min);
	m->max_cost = INFINITY;
	MBMAP(m)->has_bound = 1;

	dv("%s: cost low bound=%f exceeded beta=%f\n", DESCM(m), m->min_cost, beta);
}

static void mm_solve_chain_v(struct fhk_graph *G, struct fhk_var *y, double beta){
	fhk_vbmap *bm = VBMAP(y);

	assert(bm->has_bound);

	if(CHAINSELECTED(bm))
		return;

	if(y->min_cost >= beta)
		return;

	assert(!MARKED(bm));
	DD(MARK(bm));

	assert(y->n_mod >= 1);

	if(y->n_mod == 1){
		struct fhk_model *m = y->models[0];
		mm_solve_chain_m(G, m, beta);

		assert((m->min_cost == m->max_cost) || m->min_cost >= beta);

		y->min_cost = m->min_cost;
		y->max_cost = m->max_cost;

		if(m->min_cost >= beta){
			dv("%s: only model cost=%f exceeded low bound=%f\n", DESCV(y), m->min_cost, beta);
			goto out;
		}

		bm->chain_selected = 1;
		y->model = m;

		dv("%s: selected only model: %s (cost=%f)\n", DESCV(y), DESCM(m), m->min_cost);
		goto out;
	}

	for(;;){
		struct fhk_model *m1, *m2;
		mmin2(&m1, &m2, y);

		if(m1->min_cost >= beta){
			dv("%s: unable to solve below beta=%f\n", DESCV(y), beta);
			goto out;
		}

		mm_solve_chain_m(G, m1, beta);

		y->min_cost = m1->min_cost;
		if(m1->max_cost < y->max_cost)
			y->max_cost = m1->max_cost;

		if(m1->max_cost <= m2->min_cost){
			assert(m1->min_cost == m1->max_cost);

			bm->chain_selected = 1;
			y->model = m1;

			dv("%s: selected model %s with cost %f\n", DESCV(y), DESCM(m1), y->min_cost);
			goto out;
		}
	}

out:
	DD(UNMARK(bm));
}

static void mm_solve_chain_m(struct fhk_graph *G, struct fhk_model *m, double beta){
	fhk_mbmap *bm = MBMAP(m);
	assert(bm->has_bound);

	if(bm->chain_selected){
		assert(m->min_cost == m->max_cost);
		return;
	}

	if(m->min_cost >= beta)
		return;

	double beta_S = costf_inverse_S(m, beta);

	double Sc_min, Sc_max;
	double Sp_min, Sp_max;

	constraint_bounds(G, &Sc_min, &Sc_max, m);
	param_bounds(&Sp_min, &Sp_max, m);

	for(unsigned i=0;i<m->n_check;i++){
		struct fhk_var *x = m->checks[i].var;

		if(VBMAP(x)->has_value)
			continue;

		// for constraints, the value matters, not the cost
		// so we actually solve the value here
		mm_solve_value(G, x);

		// recompute full bounds here since other constraints may
		// have been solved as a side-effect of solving x.
		// (could also add cost deltas then recompute after solving all)
		constraint_bounds(G, &Sc_min, &Sc_max, m);

		// constraint_bounds() can trigger calculation of params
		// XXX: this is a hack, most constraint_bounds & param_bounds calls in this function
		// should be replaced by deltas.
		param_bounds(&Sp_min, &Sp_max, m);

		if(Sc_min + Sp_min >= beta_S)
			goto betabound;
	}

	assert(Sc_min == Sc_max);

	for(unsigned i=0;i<m->n_param;i++){
		struct fhk_var *x = m->params[i];

		if(CHAINSELECTED(VBMAP(x)))
			continue;

		// here Sp_min - x->min_cost is
		//     sum  (y->min_cost)
		//     y!=x 
		// 
		// this call will either exit with chain_selected=1 or cost exceeds beta
		mm_solve_chain_v(G, x, beta_S - (Sc_min + Sp_min - x->min_cost));

		param_bounds(&Sp_min, &Sp_max, m);

		if(Sc_min + Sp_min >= beta_S)
			goto betabound;

		// didn't jump to betabound so mm_solve_chain_v must have solved the chain
		assert(CHAINSELECTED(VBMAP(x)));
	}

	assert(Sp_min == Sp_max);

	m->min_cost = costf(m, Sc_min + Sp_min);
	m->max_cost = m->min_cost;
	bm->chain_selected = 1;
	dv("%s: solved chain, cost: %f (S=%f+%f)\n", DESCM(m), m->min_cost, Sc_min, Sp_min);
	return;

betabound:
	m->min_cost = costf(m, Sc_min + Sp_min);
	m->max_cost = costf(m, Sc_max + Sp_max);
	dv("%s: min cost=%f (S=%f+%f) exceeded beta=%f\n",
			DESCM(m),
			m->min_cost,
			Sc_min, Sp_min,
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

	for(unsigned i=0;i<y->n_mod;i++){
		struct fhk_model *m = y->models[i];

		if(m->min_cost <= y->max_cost && !UNSOLVABLE(m))
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
	double beta_S = costf_inverse_S(m, beta);

	double Sp_min, Sp_max;
	double Sc_min, Sc_max;

	constraint_bounds(G, &Sc_min, &Sc_max, m);
	param_bounds(&Sp_min, &Sp_max, m);

	if(Sc_min + Sp_min >= beta_S)
		goto betabound;

	for(unsigned i=0;i<m->n_check;i++){
		struct fhk_var *x = m->checks[i].var;

		resolve_value(G, x);

		// unlike in mm_solve_chain_m, here all variable chains have been fully solved
		// and the only thing that can affect cost if constraints so we don't need to
		// recompute param bounds
		constraint_bounds(G, &Sc_min, &Sc_max, m);

		if(Sc_min + Sp_min >= beta_S)
			goto betabound;
	}

	assert(Sc_min == Sc_max && Sp_min == Sp_max);
	m->min_cost = costf(m, Sc_min + Sp_min);
	m->max_cost = m->min_cost;
	bm->chain_selected = 1;
	dv("%s: solved chain, cost: %f (S=%f+%f)\n", DESCM(m), COST(m), Sc_min, Sp_min);

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
	double min_cost = costf(m, Sc_min + Sp_min);
	dv("%s: min cost=%f (S=%f+%f) exceeded all existing costs (beta=%f)\n",
			DESCM(m),
			min_cost,
			Sc_min,
			Sp_min,
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
		if(!MARKED(bm))
			continue;

		if(!CHAINSELECTED(bm)){
			double cost = next.cost;
			assert(cost >= x->min_cost && cost <= x->max_cost);
			assert(MBMAP(x->model)->chain_selected && cost == COST(x->model));
			x->min_cost = cost;
			x->max_cost = cost;
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

	if(nsolved < nv){
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

static void exec_chain(struct fhk_graph *G, struct fhk_var *y){
	fhk_vbmap *bm = VBMAP(y);

	if(bm->has_value)
		return;

	assert(bm->chain_selected);
	struct fhk_model *m = y->model;

	if(!MBMAP(m)->has_return){
		for(size_t i=0;i<m->n_param;i++){
			// this won't cause problems because the selected chain will never have a loop
			// Note: we don't need to check UNSOLVABLE here anymore, if we are here then
			// we must have a finite cost
			resolve_value(G, m->params[i]);
		}

		exec_model(G, m);
	}

	y->value = *return_ptr(m, y);
	bm->has_value = 1;
	dv("solved %s -> %f / %#lx\n", DESCV(y), y->value.f64, y->value.u64);
}

static void exec_model(struct fhk_graph *G, struct fhk_model *m){
	assert(!MBMAP(m)->has_return);

	pvalue args[m->n_param];
	for(size_t i=0;i<m->n_param;i++)
		args[i] = m->params[i]->value;

	if(G->exec_model(G, m->udata, m->rvals, args))
		FAIL(FHK_MODEL_FAILED, m, NULL);

	MBMAP(m)->has_return = 1;
}

// Note that costf must be increasing in S, non-negative (for non-negative S),
// and it must have the property
//    costf(inf) = inf
// This also implies
//    costf_inverse_S(inf) = inf
//
// It doesn't necessarily need to be this linear function.
static double costf(struct fhk_model *m, double S){
	return m->k + m->c*S;
}

static double costf_inverse_S(struct fhk_model *m, double cost){
	// XXX if needed, 1/c can be precomputed to turn this into a multiplication
	return (cost - m->k) / m->c;
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

static void resolve_given(struct fhk_graph *G, struct fhk_var *x){
	fhk_vbmap *bm = VBMAP(x);

	assert(bm->given);

	if(bm->has_value)
		return;

	int r = G->resolve_var(G, x->udata, &x->value);
	if(r != FHK_OK)
		FAIL(FHK_VAR_FAILED, NULL, x);

	bm->has_value = 1;
	dv("virtual %s -> %f / %#lx\n", DESCV(x), x->value.f64, x->value.u64);
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

static void constraint_bounds(struct fhk_graph *G, double *Sc_min, double *Sc_max,
		struct fhk_model *m){

	double min = 0, max = 0;

	for(size_t i=0;i<m->n_check;i++){
		struct fhk_check *c = &m->checks[i];
		struct fhk_var *x = c->var;

		if(VBMAP(x)->given)
			resolve_given(G, x);

		if(VBMAP(x)->has_value){
			double cost = c->costs[check_cst(&c->cst, x->value)];
			min += cost;
			max += cost;
		}else{
			min += c->costs[FHK_COST_IN];
			max += c->costs[FHK_COST_OUT];
		}
	}

	*Sc_min = min;
	*Sc_max = max;
}

static void param_bounds(double *Sp_min, double *Sp_max, struct fhk_model *m){
	double min = 0, max = 0;

	for(size_t i=0;i<m->n_param;i++){
		struct fhk_var *x = m->params[i];

		min += x->min_cost;
		max += x->max_cost;
	}

	*Sp_min = min;
	*Sp_max = max;
}

static void mmin2(struct fhk_model **m1, struct fhk_model **m2, struct fhk_var *y){
	assert(y->n_mod >= 2);

	struct fhk_model **m = y->models;
	double xa = m[0]->min_cost;
	double xb = m[1]->min_cost;
	unsigned a = xa > xb;
	unsigned b = 1 - a;

	size_t n = y->n_mod;
	for(unsigned i=2;i<n;i++){
		double xc = m[i]->min_cost;

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
		if(m[i]->n_param > 0)
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
	for(unsigned i=0;i<m->n_return;i++){
		if(m->returns[i] == v)
			return &m->rvals[i];
	}

	UNREACHABLE();
}

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
