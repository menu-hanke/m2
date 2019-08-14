#include "def.h"
#include "fhk.h"

#include <string.h>
#include <math.h>
#include <setjmp.h>
#include <assert.h>

struct state {
	struct fhk_graph *G;
	jmp_buf exc_env;
	struct fhk_einfo error;
	DD(char debugv[64]);
	DD(char debugm[64]);
};

static void mm_bound_cost_v(struct state *s, struct fhk_var *y, double beta);
static void mm_bound_init_v(struct state *s, struct fhk_var *y, double beta);
static void mm_bound_cost_m(struct state *s, struct fhk_model *m, double beta);
static void mm_solve_chain_v(struct state *s, struct fhk_var *y, double beta);
static void mm_solve_chain_m(struct state *s, struct fhk_model *m, double beta);
static void mm_solve_value(struct state *s, struct fhk_var *y);

static void exec_chain(struct state *s, struct fhk_var *y);
static void exec_model(struct state *s, struct fhk_model *m);

static double costf(struct fhk_model *m, double S);
static double costf_inverse_S(struct fhk_model *m, double cost);
static void stabilize(struct state *s, struct fhk_var *y);
static int check_cst(struct fhk_cst *cst, pvalue v);
static void constraint_bounds(double *Sc_min, double *Sc_max, struct state *s, struct fhk_model *m);
static void resolve_given(struct state *s, struct fhk_var *x);
static void param_bounds(double *Sp_min, double *Sp_max, struct fhk_model *m);
static void mmin2(unsigned *m1, unsigned *m2, struct fhk_var *y);

#define UNSOLVABLE(e) ISPINF((e)->min_cost)
#define VM_CHAINSELECTED(vm) ((vm)->chain_selected || (vm)->given)
#define ISPINF(x) (isinf(x) && (x)>0)
#define VBMAP(s, y) (s)->G->v_bitmaps[(y)->idx]
#define MBMAP(s, m) (s)->G->m_bitmaps[(m)->idx]
#define FAIL(res, m, v) do { dv("solver: failed: " #res "\n"); fail(s, res, m, v); } while(0)
static void fail(struct state *s, int res, struct fhk_model *m, struct fhk_var *v);
DD(static const char *ddescv(struct state *s, struct fhk_var *y));
DD(static const char *ddescm(struct state *s, struct fhk_model *m));

int fhk_solve(struct fhk_graph *G, struct fhk_var *y){
	struct state s;
	s.G = G;

	assert(VBMAP(&s, y).solve);

	if(setjmp(s.exc_env)){
		// TODO
		assert(0);
	}

	// this will longjmp there ^^^^^ if something goes wrong
	// if the call returns we have our value and all went good
	mm_solve_value(&s, y);
	return FHK_OK;
}

static void mm_bound_cost_v(struct state *s, struct fhk_var *y, double beta){
	fhk_vbmap *bm = &VBMAP(s, y);

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
	assert(!bm->solving);

	bm->solving = 1;

	for(size_t i=0;i<y->n_mod;i++){
		struct fhk_model *m = y->models[i];
		mm_bound_cost_m(s, m, beta);

		if(m->max_cost < beta)
			beta = m->max_cost;
	}

	bm->solving = 0;

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

static void mm_bound_init_v(struct state *s, struct fhk_var *y, double beta){
	if(VBMAP(s, y).solve)
		mm_solve_value(s, y);
	else
		mm_bound_cost_v(s, y, beta);
}

static void mm_bound_cost_m(struct state *s, struct fhk_model *m, double beta){
	if(MBMAP(s, m).has_bound)
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

		if(VBMAP(s, x).solving){
			// Solver will hit a cycle, but don't give up.
			// If another chain will be chosen for x, we may still be able to use
			// this model in the future.
			// We can still get a valid low cost bound for the model.
			S_max = INFINITY;
			dv("%s: cycle caused by param: %s\n", ddescm(s, m), ddescv(s, x));
			continue;
		}

		mm_bound_init_v(s, x, beta_S - S_min);

		S_min += x->min_cost;
		S_max += x->max_cost;

		if(S_min >= beta_S)
			goto betabound;
	}

	m->min_cost = costf(m, S_min);
	m->max_cost = costf(m, S_max);
	MBMAP(s, m).has_bound = 1;

	dv("%s: bounded cost in [%f, %f]\n", ddescm(s, m), m->min_cost, m->max_cost);

	assert(m->max_cost >= m->min_cost);
	assert(beta > m->min_cost);

	return;

betabound:
	m->min_cost = costf(m, S_min);
	m->max_cost = INFINITY;
	MBMAP(s, m).has_bound = 1;

	dv("%s: cost low bound=%f exceeded beta=%f\n", ddescm(s, m), m->min_cost, beta);
}

static void mm_solve_chain_v(struct state *s, struct fhk_var *y, double beta){
	fhk_vbmap *bm = &VBMAP(s, y);

	assert(bm->stable && bm->has_bound);

	if(VM_CHAINSELECTED(bm))
		return;

	if(y->min_cost >= beta)
		return;

	// HUOM: tässä voisi vielä jatkaa, ks. lua
	if(bm->solving)
		FAIL(FHK_CYCLE, NULL, y);

	bm->solving = 1;

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
		y->select_model = 0;

		dv("%s: selected only model: %s (cost=%f)\n", ddescv(s, y), ddescm(s, m), m->min_cost);
		goto out;
	}

	for(;;){
		unsigned midx1, midx2;
		mmin2(&midx1, &midx2, y);

		struct fhk_model *m1 = y->models[midx1];
		struct fhk_model *m2 = y->models[midx2];

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
			y->select_model = midx1;

			dv("%s: selected model %s with cost %f\n", ddescv(s, y), ddescm(s, m1), y->min_cost);
			goto out;
		}
	}

out:
	bm->solving = 0;
}

static void mm_solve_chain_m(struct state *s, struct fhk_model *m, double beta){
	fhk_mbmap *bm = &MBMAP(s, m);
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

	// XXX could do inf checks first here to fail faster
	for(size_t i=0;i<m->n_check;i++){
		struct fhk_var *x = m->checks[i].var;

		if(VBMAP(s, x).has_value || UNSOLVABLE(x))
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

	for(size_t i=0;i<m->n_param;i++){
		struct fhk_var *x = m->params[i];

		if(VM_CHAINSELECTED(&VBMAP(s, x)))
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
	stabilize(s, y);

	fhk_vbmap *bm = &VBMAP(s, y);

	if(bm->has_value || UNSOLVABLE(y))
		return;

	mm_bound_cost_v(s, y, INFINITY);
	mm_solve_chain_v(s, y, INFINITY);

	assert(bm->chain_selected || UNSOLVABLE(y));

	if(UNSOLVABLE(y)){
		if(bm->solve)
			FAIL(FHK_REQUIRED_UNSOLVABLE, NULL, y);
		return;
	}

	exec_chain(s, y);

	// TODO check invariants/retvalchecks (?)
}

static void exec_chain(struct state *s, struct fhk_var *y){
	fhk_vbmap *bm = &VBMAP(s, y);

	if(bm->has_value)
		return;

	assert(bm->chain_selected);
	struct fhk_model *m = y->models[y->select_model];

	if(!MBMAP(s, m).has_return){
		for(size_t i=0;i<m->n_param;i++){
			// this won't cause problems because the selected chain will never have a loop
			// Note: we don't need to check UNSOLVABLE here anymore, if we are here then
			// we must have a finite cost
			struct fhk_var *x = m->params[i];

			if(VBMAP(s, x).given)
				resolve_given(s, x);
			else
				exec_chain(s, x);

			assert(VBMAP(s, x).has_value);
		}

		exec_model(s, m);
	}

	y->value = *y->mret[y->select_model];
	bm->has_value = 1;

	if(s->G->chain_solved)
		s->G->chain_solved(s->G, y->udata, y->value);
}

static void exec_model(struct state *s, struct fhk_model *m){
	assert(!MBMAP(s, m).has_return);

	pvalue args[m->n_param];
	for(size_t i=0;i<m->n_param;i++)
		args[i] = m->params[i]->value;

	if(s->G->exec_model(s->G, m->udata, m->returns, args))
		FAIL(FHK_MODEL_FAILED, m, NULL);

	MBMAP(s, m).has_return = 1;
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
	fhk_vbmap *bm = &VBMAP(s, y);

	if(bm->stable)
		return;

	int r = s->G->resolve_var(s->G, y->udata, &y->value);

	dv("stabilize %s -> (%s) %f / %#lx\n",
			ddescv(s, y),
			(r == FHK_OK) ? "resolved" :
			(r == FHK_NOT_RESOLVED) ? "not resolved" : "error",
			y->value.r,
			y->value.b
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

static void resolve_given(struct state *s, struct fhk_var *x){
	fhk_vbmap *bm = &VBMAP(s, x);

	assert(bm->stable && bm->given);

	if(bm->has_value)
		return;

	int r = s->G->resolve_var(s->G, x->udata, &x->value);
	if(r != FHK_OK)
		FAIL(FHK_RESOLVE_FAILED, NULL, x);

	bm->has_value = 1;
	dv("virtual %s -> %f / %#lx\n", ddescv(s, x), x->value.r, x->value.b);
}

static int check_cst(struct fhk_cst *cst, pvalue v){
	switch(cst->type){

		case FHK_RIVAL:
			return v.r >= cst->rival.min && v.r <= cst->rival.max;

		case FHK_BITSET:
			//dv("check bitset b=%#lx mask=0%#lx\n", v.b, cst->setmask);
			return !!(v.b & cst->setmask);
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

		assert(VBMAP(s, x).stable);

		if(VBMAP(s, x).given)
			resolve_given(s, x);

		if(VBMAP(s, x).has_value){
			double cost = c->costs[check_cst(&c->cst, x->value)];
			min += cost;
			max += cost;
		}else if(UNSOLVABLE(x)){
			min += c->costs[FHK_COST_OUT];
			max += c->costs[FHK_COST_OUT];
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

static void mmin2(unsigned *m1, unsigned *m2, struct fhk_var *y){
	assert(y->n_mod >= 2);

	struct fhk_model **m = y->models;
	double xa = m[0]->min_cost;
	double xb = m[1]->min_cost;
	unsigned a = xa > xb;
	unsigned b = 1 - a;

	size_t n = y->n_mod;
#define swap(A, B) do { typeof(A) _t = (A); (A) = (B); (B) = _t; } while(0)
	for(size_t i=2;i<n;i++){
		double xc = m[i]->min_cost;

		if(xc < xb){
			xb = xc;
			b = i;

			if(xb < xa){
				swap(xa, xb);
				swap(a, b);
			}
		}
	}
#undef swap

	*m1 = a;
	*m2 = b;
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
