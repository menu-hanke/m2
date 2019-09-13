#include "def.h"
#include "fhk.h"

#include <stddef.h>
#include <string.h>
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

struct state {
	struct fhk_graph *G;
	struct heap *heap;
	unsigned cycle : 1;
	jmp_buf exc_env;
	DD(char debugv[64]);
	DD(char debugm[64]);
};

static void mm_bound_cost_v(struct state *s, struct fhk_var *y, double beta);
static void mm_bound_cost_m(struct state *s, struct fhk_model *m, double beta);
static void mm_solve_chain_v(struct state *s, struct fhk_var *y, double beta);
static void mm_solve_chain_m(struct state *s, struct fhk_model *m, double beta);
static void mm_solve_value(struct state *s, struct fhk_var *y);

static void dj_mark_v(struct state *s, struct fhk_var *y);
static void dj_mark_m(struct state *s, struct fhk_model *m);
static void dj_visit_v(struct state *s, struct fhk_var *y);
static void dj_visit_m(struct state *s, struct fhk_model *m);
static double dj_beta_m(struct state *s, struct fhk_model *m);
static void dj_offer_v(struct state *s, struct fhk_var *y, struct fhk_model *m);
static void dj_solve_heap(struct state *s, size_t need);
static void dj_solve_bounded(struct state *s, size_t nv, struct fhk_var **ys);

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

static void exec_chain(struct state *s, struct fhk_var *y);
static void exec_model(struct state *s, struct fhk_model *m);

static double costf(struct fhk_model *m, double S);
static double costf_inverse_S(struct fhk_model *m, double cost);
static void stabilize(struct state *s, struct fhk_var *y);
static int check_cst(struct fhk_cst *cst, pvalue v);
static void constraint_bounds(double *Sc_min, double *Sc_max, struct state *s, struct fhk_model *m);
static void resolve_value(struct state *s, struct fhk_var *x);
static void resolve_given(struct state *s, struct fhk_var *x);
static void param_bounds(double *Sp_min, double *Sp_max, struct fhk_model *m);
static void mmin2(struct fhk_model **m1, struct fhk_model **m2, struct fhk_var *y);
static pvalue *return_ptr(struct fhk_model *m, struct fhk_var *v);

#define SWAP(A, B) do { typeof(A) _t = (A); (A) = (B); (B) = _t; } while(0)
#define COST(e) ({ assert((e)->min_cost == (e)->max_cost); (e)->min_cost; })
#define UNSOLVABLE(e) ISPINF((e)->min_cost)
#define CHAINSELECTED(vm) ((vm)->chain_selected || (vm)->given)
#define ISPINF(x) (isinf(x) && (x)>0)
#define VBMAP(s, y) (&(s)->G->v_bitmaps[(y)->idx])
#define MBMAP(s, m) (&(s)->G->m_bitmaps[(m)->idx])
#define MARKED(m)   (m)->mark
#define MARK(m)     MARKED(m) = 1
#define UNMARK(m)   MARKED(m) = 0
#define FAIL(res, m, v) do { dv("solver: failed: " #res "\n"); fail(s, res, m, v); } while(0)
static void fail(struct state *s, int res, struct fhk_model *m, struct fhk_var *v);
DD(static const char *ddescv(struct state *s, struct fhk_var *y));
DD(static const char *ddescm(struct state *s, struct fhk_model *m));

int fhk_solve(struct fhk_graph *G, size_t nv, struct fhk_var **ys){
	assert(!G->dirty);
	DD(G->dirty = 1);

	struct state s;
	s.G = G;
	s.cycle = 0;

	if(setjmp(s.exc_env))
		return G->last_error.err;

	for(size_t i=0;i<nv;i++){
		struct fhk_var *y = ys[i];
		mm_bound_cost_v(&s, y, INFINITY);
		if(UNSOLVABLE(y))
			fail(&s, FHK_SOLVER_FAILED, NULL, y);
	}

	if(s.cycle){
		dv("Cycle detected, using dijkstra solver\n");
		dj_solve_bounded(&s, nv, ys);
	}else{
		for(size_t i=0;i<nv;i++)
			mm_solve_value(&s, ys[i]);
	}

	return FHK_OK;
}

static void mm_bound_cost_v(struct state *s, struct fhk_var *y, double beta){
	fhk_vbmap *bm = VBMAP(s, y);

	if(bm->has_bound)
		return;

	stabilize(s, y);

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
		mm_bound_cost_m(s, m, beta);

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

	dv("Bounded var %s in [%f, %f]\n", ddescv(s, y), min, max);
}

static void mm_bound_cost_m(struct state *s, struct fhk_model *m, double beta){
	if(MBMAP(s, m)->has_bound)
		return;

	for(size_t i=0;i<m->n_check;i++)
		stabilize(s, m->checks[i].var);

	double beta_S = costf_inverse_S(m, beta);

	double S_min, S_max;
	constraint_bounds(&S_min, &S_max, s, m);

	if(S_min >= beta_S){
		dv("%s: beta bound from constraints (%f >= %f)\n", ddescm(s, m), S_min, beta_S);
		goto betabound;
	}

	for(size_t i=0;i<m->n_param;i++){
		struct fhk_var *x = m->params[i];

		if(MARKED(VBMAP(s, x))){
			// Solver will hit a cycle, but don't give up.
			// If another chain will be chosen for x, we may still be able to use
			// this model in the future.
			// We can still get a valid low cost bound for the model.
			s->cycle = 1;
			S_max = INFINITY;
			dv("%s: cycle caused by param: %s\n", ddescm(s, m), ddescv(s, x));
			continue;
		}

		mm_bound_cost_v(s, x, beta_S - S_min);

		S_min += x->min_cost;
		S_max += x->max_cost;

		if(S_min >= beta_S)
			goto betabound;
	}

	m->min_cost = costf(m, S_min);
	m->max_cost = costf(m, S_max);
	MBMAP(s, m)->has_bound = 1;

	dv("%s: bounded cost in [%f, %f]\n", ddescm(s, m), m->min_cost, m->max_cost);

	assert(m->max_cost >= m->min_cost);
	assert(beta > m->min_cost);

	return;

betabound:
	m->min_cost = costf(m, S_min);
	m->max_cost = INFINITY;
	MBMAP(s, m)->has_bound = 1;

	dv("%s: cost low bound=%f exceeded beta=%f\n", ddescm(s, m), m->min_cost, beta);
}

static void mm_solve_chain_v(struct state *s, struct fhk_var *y, double beta){
	fhk_vbmap *bm = VBMAP(s, y);

	assert(bm->stable && bm->has_bound);

	if(CHAINSELECTED(bm))
		return;

	if(y->min_cost >= beta)
		return;

	assert(!MARKED(bm));
	DD(MARK(bm));

	assert(y->n_mod>= 1);

	if(y->n_mod == 1){
		struct fhk_model *m = y->models[0];
		mm_solve_chain_m(s, m, beta);

		assert((m->min_cost == m->max_cost) || m->min_cost >= beta);

		y->min_cost = m->min_cost;
		y->max_cost = m->max_cost;

		if(m->min_cost >= beta){
			dv("%s: only model cost=%f exceeded low bound=%f\n", ddescv(s, y), m->min_cost, beta);
			goto out;
		}

		bm->chain_selected = 1;
		y->model = m;

		dv("%s: selected only model: %s (cost=%f)\n", ddescv(s, y), ddescm(s, m), m->min_cost);
		goto out;
	}

	for(;;){
		struct fhk_model *m1, *m2;
		mmin2(&m1, &m2, y);

		if(m1->min_cost >= beta){
			dv("%s: unable to solve below beta=%f\n", ddescv(s, y), beta);
			goto out;
		}

		mm_solve_chain_m(s, m1, beta);

		y->min_cost = m1->min_cost;
		if(m1->max_cost < y->max_cost)
			y->max_cost = m1->max_cost;

		if(m1->max_cost <= m2->min_cost){
			assert(m1->min_cost == m1->max_cost);

			bm->chain_selected = 1;
			y->model = m1;

			dv("%s: selected model %s with cost %f\n", ddescv(s, y), ddescm(s, m1), y->min_cost);
			goto out;
		}
	}

out:
	DD(UNMARK(bm));
}

static void mm_solve_chain_m(struct state *s, struct fhk_model *m, double beta){
	fhk_mbmap *bm = MBMAP(s, m);
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

	constraint_bounds(&Sc_min, &Sc_max, s, m);
	param_bounds(&Sp_min, &Sp_max, m);

	for(unsigned i=0;i<m->n_check;i++){
		struct fhk_var *x = m->checks[i].var;

		if(VBMAP(s, x)->has_value)
			continue;

		// for constraints, the value matters, not the cost
		// so we actually solve the value here
		mm_solve_value(s, x);

		// recompute full bounds here since other constraints may
		// have been solved as a side-effect of solving x.
		// (could also add cost deltas then recompute after solving all)
		constraint_bounds(&Sc_min, &Sc_max, s, m);

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

		if(CHAINSELECTED(VBMAP(s, x)))
			continue;

		// here Sp_min - x->min_cost is
		//     sum  (y->min_cost)
		//     y!=x 
		// 
		// this call will either exit with chain_selected=1 or cost exceeds beta
		mm_solve_chain_v(s, x, beta_S - (Sc_min + Sp_min - x->min_cost));

		param_bounds(&Sp_min, &Sp_max, m);

		if(Sc_min + Sp_min >= beta_S)
			goto betabound;
	}

	assert(Sp_min == Sp_max);

	m->min_cost = costf(m, Sc_min + Sp_min);
	m->max_cost = m->min_cost;
	bm->chain_selected = 1;
	dv("%s: solved chain, cost: %f (S=%f+%f)\n", ddescm(s, m), m->min_cost, Sc_min, Sp_min);
	return;

betabound:
	m->min_cost = costf(m, Sc_min + Sp_min);
	m->max_cost = costf(m, Sc_max + Sp_max);
	dv("%s: min cost=%f (S=%f+%f) exceeded beta=%f\n",
			ddescm(s, m),
			m->min_cost,
			Sc_min, Sp_min,
			beta
	);
}

static void mm_solve_value(struct state *s, struct fhk_var *y){
	fhk_vbmap *bm = VBMAP(s, y);
	assert(bm->stable && bm->has_bound);

	if(bm->has_value || UNSOLVABLE(y))
		return;

	mm_solve_chain_v(s, y, INFINITY);
	assert(bm->chain_selected || UNSOLVABLE(y));

	if(!UNSOLVABLE(y))
		resolve_value(s, y);
}

static void dj_mark_v(struct state *s, struct fhk_var *y){
	fhk_vbmap *bm = VBMAP(s, y);
	assert(bm->stable && bm->has_bound);

	if(MARKED(bm))
		return;

	MARK(bm);
	y->hptr = 0;

	if(CHAINSELECTED(bm)){
		dv("Search root: %s (chain cost: %f)\n", ddescv(s, y), COST(y));
		heap_add_unordered(s->heap, y, COST(y));
		return;
	}

	for(unsigned i=0;i<y->n_mod;i++){
		struct fhk_model *m = y->models[i];

		if(m->min_cost <= y->max_cost && !UNSOLVABLE(m))
			dj_mark_m(s, m);
	}
}

static void dj_mark_m(struct state *s, struct fhk_model *m){
	fhk_mbmap *bm = MBMAP(s, m);
	assert(bm->has_bound);

	if(MARKED(bm))
		return;

	MARK(bm);

	for(unsigned i=0;i<m->n_param;i++)
		dj_mark_v(s, m->params[i]);
}

static void dj_visit_v(struct state *s, struct fhk_var *y){
	fhk_vbmap *bm = VBMAP(s, y);
	assert(MARKED(bm) && CHAINSELECTED(bm));

	// Note: this is an inefficient way to do the check, ways to optimize this are:
	// * during marking, collect the models in the subgraph to a separate array and iterate
	//   over that
	// * store a count/bitmap of solved parameters per model instead of re-checking all
	
	for(unsigned i=0;i<y->n_fwd;i++){
		struct fhk_model *m = y->fwd_models[i];

		if(!MARKED(MBMAP(s, m)))
			continue;

		dj_visit_m(s, m);
	}
}

static void dj_visit_m(struct state *s, struct fhk_model *m){
	fhk_mbmap *bm = MBMAP(s, m);
	assert(MARKED(bm) && !bm->chain_selected);

	for(unsigned i=0;i<m->n_param;i++){
		struct fhk_var *x = m->params[i];

		if(!CHAINSELECTED(VBMAP(s, x)))
			return;
	}

	double beta = dj_beta_m(s, m);
	double beta_S = costf_inverse_S(m, beta);

	double Sp_min, Sp_max;
	double Sc_min, Sc_max;

	constraint_bounds(&Sc_min, &Sc_max, s, m);
	param_bounds(&Sp_min, &Sp_max, m);

	if(Sc_min + Sp_min >= beta_S)
		goto betabound;

	for(unsigned i=0;i<m->n_check;i++){
		struct fhk_var *x = m->checks[i].var;

		resolve_value(s, x);

		// unlike in mm_solve_chain_m, here all variable chains have been fully solved
		// and the only thing that can affect cost if constraints so we don't need to
		// recompute param bounds
		constraint_bounds(&Sc_min, &Sc_max, s, m);

		if(Sc_min + Sp_min >= beta_S)
			goto betabound;
	}

	assert(Sc_min == Sc_max && Sp_min == Sp_max);
	m->min_cost = costf(m, Sc_min + Sp_min);
	m->max_cost = m->min_cost;
	bm->chain_selected = 1;
	dv("%s: solved chain, cost: %f (S=%f+%f)\n", ddescm(s, m), COST(m), Sc_min, Sp_min);

	for(unsigned i=0;i<m->n_return;i++){
		struct fhk_var *y = m->returns[i];
		fhk_vbmap *vm = VBMAP(s, y);

		if(MARKED(vm) && !CHAINSELECTED(vm))
			dj_offer_v(s, y, m);
	}

	return;

betabound:
	// unmark for debugging so the assert fails if we ever try to touch this model again
	DD(UNMARK(bm));
	double min_cost = costf(m, Sc_min + Sp_min);
	dv("%s: min cost=%f (S=%f+%f) exceeded all existing costs (beta=%f)\n",
			ddescm(s, m),
			min_cost,
			Sc_min,
			Sp_min,
			beta
	);
}

static double dj_beta_m(struct state *s, struct fhk_model *m){
	double beta = 0;

	for(unsigned i=0;i<m->n_return;i++){
		struct fhk_var *y = m->returns[i];
		fhk_vbmap *bm = VBMAP(s, y);

		if(CHAINSELECTED(bm))
			continue;

		if(MARKED(bm) && y->hptr>0){
			double cost = s->heap->ent[y->hptr].cost;
			if(cost > beta)
				beta = cost;
			continue;
		}

		return INFINITY;
	}

	return beta;
}

static void dj_offer_v(struct state *s, struct fhk_var *y, struct fhk_model *m){
	double cost = COST(m);

	if(y->hptr > 0){
		struct heap_ent *ent = &s->heap->ent[y->hptr];
		if(cost >= HEAP_COST(*ent))
			return;

		dv("%s: new candidate: %s -> %s (cost: %f -> %f)\n",
				ddescv(s, y),
				ddescm(s, y->model),
				ddescm(s, m),
				COST(y->model),
				cost
		);

		HEAP_COST(*ent) = cost;
		y->model = m;
		heap_decr_cost(s->heap, y->hptr);
	}else{
		dv("%s: first candidate: %s (cost: %f)\n", ddescv(s, y), ddescm(s, m), cost);

		y->model = m;
		heap_add(s->heap, y, cost);
	}

}

static void dj_solve_heap(struct state *s, size_t need){
	assert(need > 0);
	struct heap *h = s->heap;

	while(h->end > 0){
		struct heap_ent next = heap_extract_min(h);
		struct fhk_var *x = next.var;

		fhk_vbmap *bm = VBMAP(s, x);

		// technically non-marked variables can go here from multi-return models
		// where we are asked to solve only a subset of the variables
		if(!MARKED(bm))
			continue;

		if(!CHAINSELECTED(bm)){
			double cost = next.cost;
			assert(cost >= x->min_cost && cost <= x->max_cost);
			assert(MBMAP(s, x->model)->chain_selected && cost == COST(x->model));
			x->min_cost = cost;
			x->max_cost = cost;
			bm->chain_selected = 1;
			dv("%s: selected model %s (cost: %f)\n",
					ddescv(s, x),
					ddescm(s, x->model),
					COST(x->model)
			);

			if(bm->target && !--need)
				return;
		}

		dj_visit_v(s, x);
	}

	FAIL(FHK_SOLVER_FAILED, NULL, NULL);
}

static void dj_solve_bounded(struct state *s, size_t nv, struct fhk_var **ys){
	size_t nsolved = 0;

	for(size_t i=0;i<nv;i++){
		fhk_vbmap *bm = VBMAP(s, ys[i]);
		assert(bm->stable);

		bm->target = 1;
		if(CHAINSELECTED(bm))
			nsolved++;
	}

	if(nsolved < nv){
		struct heap h;
		h.end = 0;
		s->heap = &h;
		for(size_t i=0;i<nv;i++)
			dj_mark_v(s, ys[i]);
		heapify(&h);

		dj_solve_heap(s, nv - nsolved);
	}

	for(size_t i=0;i<nv;i++){
		fhk_vbmap *bm = VBMAP(s, ys[i]);
		assert(CHAINSELECTED(bm));
		resolve_value(s, ys[i]);
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

static void exec_chain(struct state *s, struct fhk_var *y){
	fhk_vbmap *bm = VBMAP(s, y);

	if(bm->has_value)
		return;

	assert(bm->chain_selected);
	struct fhk_model *m = y->model;

	if(!MBMAP(s, m)->has_return){
		for(size_t i=0;i<m->n_param;i++){
			// this won't cause problems because the selected chain will never have a loop
			// Note: we don't need to check UNSOLVABLE here anymore, if we are here then
			// we must have a finite cost
			resolve_value(s, m->params[i]);
		}

		exec_model(s, m);
	}

	y->value = *return_ptr(m, y);
	bm->has_value = 1;
	dv("solved %s -> %f / %#lx\n", ddescv(s, y), y->value.f64, y->value.u64);

	if(s->G->chain_solved)
		s->G->chain_solved(s->G, y->udata, y->value);
}

static void exec_model(struct state *s, struct fhk_model *m){
	assert(!MBMAP(s, m)->has_return);

	pvalue args[m->n_param];
	for(size_t i=0;i<m->n_param;i++)
		args[i] = m->params[i]->value;

	if(s->G->exec_model(s->G, m->udata, m->rvals, args))
		FAIL(FHK_MODEL_FAILED, m, NULL);

	MBMAP(s, m)->has_return = 1;
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

static void stabilize(struct state *s, struct fhk_var *y){
	fhk_vbmap *bm = VBMAP(s, y);

	if(bm->stable)
		return;

	int r = s->G->resolve_var(s->G, y->udata, &y->value);

	dv("stabilize %s -> (%s) %f / %#lx\n",
			ddescv(s, y),
			(r == FHK_OK) ? "resolved" :
			(r == FHK_NOT_RESOLVED) ? "not resolved" : "error",
			y->value.f64,
			y->value.u64
	);

	if(r == FHK_OK){
		bm->stable = 1;
		bm->given = 1;
		bm->has_value = 1;
	}else if(r == FHK_NOT_RESOLVED){
		bm->stable = 1;
		bm->given = 0;
		bm->has_value = 0;
	}else{
		FAIL(FHK_RESOLVE_FAILED, NULL, y);
	}
}

static void resolve_value(struct state *s, struct fhk_var *x){
	fhk_vbmap *bm = VBMAP(s, x);
	assert(bm->stable && CHAINSELECTED(bm));

	if(bm->has_value)
		return;

	if(bm->given)
		resolve_given(s, x);
	else
		exec_chain(s, x);

	assert(bm->has_value);
}

static void resolve_given(struct state *s, struct fhk_var *x){
	fhk_vbmap *bm = VBMAP(s, x);

	assert(bm->stable && bm->given);

	if(bm->has_value)
		return;

	int r = s->G->resolve_var(s->G, x->udata, &x->value);
	if(r != FHK_OK)
		FAIL(FHK_RESOLVE_FAILED, NULL, x);

	bm->has_value = 1;
	dv("virtual %s -> %f / %#lx\n", ddescv(s, x), x->value.f64, x->value.u64);
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

static void constraint_bounds(double *Sc_min, double *Sc_max, struct state *s, struct fhk_model *m){
	double min = 0, max = 0;

	// XXX: tätä voi optimoida jollain cmov viritelmillä jne.
	// tässä aika paska toteutus

	for(size_t i=0;i<m->n_check;i++){
		struct fhk_check *c = &m->checks[i];
		struct fhk_var *x = c->var;

		assert(VBMAP(s, x)->stable);

		if(VBMAP(s, x)->given)
			resolve_given(s, x);

		if(VBMAP(s, x)->has_value){
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

static pvalue *return_ptr(struct fhk_model *m, struct fhk_var *v){
	// this is an ok way to do it since almost all models will have 1 return
	// and 99.999999999% will have at most 4-5
	for(unsigned i=0;i<m->n_return;i++){
		if(m->returns[i] == v)
			return &m->rvals[i];
	}

	UNREACHABLE();
}

static void fail(struct state *s, int res, struct fhk_model *m, struct fhk_var *v){
	struct fhk_einfo *ei = &s->G->last_error;
	ei->err = res;
	ei->model = m;
	ei->var = v;
	longjmp(s->exc_env, 1);
}

#ifdef DEBUG

static const char *ddescv(struct state *s, struct fhk_var *y){
	if(s->G->debug_desc_var)
		return s->G->debug_desc_var(y->udata);

	sprintf(s->debugv, "Var#%d", y->idx);
	return s->debugv;
}

static const char *ddescm(struct state *s, struct fhk_model *m){
	if(s->G->debug_desc_model)
		return s->G->debug_desc_model(m->udata);

	sprintf(s->debugm, "Model#%d", m->idx);
	return s->debugm;
}

#endif
