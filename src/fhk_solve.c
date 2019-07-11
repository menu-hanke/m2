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

static void exec_chain(struct state *s, struct fhk_var *y, struct fhk_model *m);
static void exec_model(struct state *s, struct fhk_var *y, struct fhk_model *m);

static double costf(struct fhk_model *m, double S);
static double costf_inverse_S(struct fhk_model *m, double cost);
static int check_cst(struct fhk_cst *cst, union pvalue v);
static void constraint_bounds(double *Sc_min, double *Sc_max, struct state *s, struct fhk_model *m);
static void resolve_given(struct state *s, struct fhk_var *x);
static void param_bounds(double *Sp_min, double *Sp_max, struct fhk_model *m);
static void mmin2(struct fhk_model **m1, struct fhk_model **m2, struct fhk_var *y);

#define UNSOLVABLE(e) ISPINF((e)->mark.min_cost)
#define VM_HASBOUND(vm) ((vm)->has_bound || (vm)->given)
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

	if(VM_HASBOUND(bm))
		return;

	// var cost bounding should never hit a cycle,
	// mm_bound_cost_m checks this flag before calling.
	assert(!bm->solving);

	bm->solving = 1;

	for(size_t i=0;i<y->n_mod;i++){
		struct fhk_model *m = y->models[i];
		mm_bound_cost_m(s, m, beta);

		if(m->mark.max_cost < beta)
			beta = m->mark.max_cost;
	}

	bm->solving = 0;

	double min = INFINITY, max = INFINITY;

	for(size_t i=0;i<y->n_mod;i++){
		struct fhk_model *m = y->models[i];

		if(m->mark.min_cost < min)
			min = m->mark.min_cost;

		if(m->mark.max_cost < max)
			max = m->mark.max_cost;
	}

	assert(max >= min);

	y->mark.min_cost = min;
	y->mark.max_cost = max;
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

		S_min += x->mark.min_cost;
		S_max += x->mark.max_cost;

		if(S_min >= beta_S)
			goto betabound;
	}

	m->mark.min_cost = costf(m, S_min);
	m->mark.max_cost = costf(m, S_max);
	MBMAP(s, m).has_bound = 1;

	dv("%s: bounded cost in [%f, %f]\n", ddescm(s, m), m->mark.min_cost, m->mark.max_cost);

	assert(m->mark.max_cost >= m->mark.min_cost);
	assert(beta > m->mark.min_cost);

	return;

betabound:
	m->mark.min_cost = costf(m, S_min);
	m->mark.max_cost = INFINITY;
	MBMAP(s, m).has_bound = 1;

	dv("%s: cost low bound=%f exceeded beta=%f\n", ddescm(s, m), m->mark.min_cost, beta);
}

static void mm_solve_chain_v(struct state *s, struct fhk_var *y, double beta){
	fhk_vbmap *bm = &VBMAP(s, y);

	assert(VM_HASBOUND(bm));

	if(VM_CHAINSELECTED(bm))
		return;

	if(y->mark.min_cost >= beta)
		return;

	// HUOM: tässä voisi vielä jatkaa, ks. lua
	if(bm->solving)
		FAIL(FHK_CYCLE, NULL, y);

	bm->solving = 1;

	assert(y->n_mod>= 1);

	if(y->n_mod == 1){
		struct fhk_model *m = y->models[0];
		mm_solve_chain_m(s, m, beta);

		assert((m->mark.min_cost == m->mark.max_cost) || m->mark.min_cost >= beta);

		y->mark.min_cost = m->mark.min_cost;
		y->mark.max_cost = m->mark.max_cost;

		if(m->mark.min_cost >= beta){
			dv("%s: only model cost=%f exceeded low bound=%f\n",
					ddescv(s, y), m->mark.min_cost, beta);
			goto out;
		}

		bm->chain_selected = 1;
		y->mark.model = m;

		dv("%s: selected only model: %s (cost=%f)\n",
				ddescv(s, y),
				ddescm(s, m),
				m->mark.min_cost
		);
		goto out;
	}

	for(;;){
		struct fhk_model *m1, *m2;
		mmin2(&m1, &m2, y);

		if(m1->mark.min_cost >= beta){
			dv("%s: unable to solve below beta=%f\n", ddescv(s, y), beta);
			goto out;
		}

		// XXX beta?
		mm_solve_chain_m(s, m1, beta);

		y->mark.min_cost = m1->mark.min_cost;
		if(m1->mark.max_cost < y->mark.max_cost)
			y->mark.max_cost = m1->mark.max_cost;

		if(m1->mark.max_cost <= m2->mark.min_cost){
			assert(m1->mark.min_cost == m1->mark.max_cost);

			bm->chain_selected = 1;
			y->mark.model = m1;

			dv("%s: selected model %s with cost %f\n",
					ddescv(s, y), ddescm(s, m1), y->mark.min_cost);
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
		assert(m->mark.min_cost == m->mark.max_cost);
		return;
	}

	if(m->mark.min_cost >= beta)
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

		// here Sp_min - x->mark.min_cost is
		//     sum  (y->mark.min_cost)
		//     y!=x 
		// 
		// this call will either exit with chain_selected=1 or cost exceeds beta
		mm_solve_chain_v(s, x, beta_S - (Sc_min + Sp_min - x->mark.min_cost));

		param_bounds(&Sp_min, &Sp_max, m);

		if(Sc_min + Sp_min >= beta_S)
			goto betabound;
	}

	assert(Sp_min == Sp_max);

	m->mark.min_cost = costf(m, Sc_min + Sp_min);
	m->mark.max_cost = m->mark.min_cost;
	bm->chain_selected = 1;
	dv("%s: solved chain, cost: %f (S=%f+%f)\n",
			ddescm(s, m),
			m->mark.min_cost,
			Sc_min, Sp_min
	);
	return;

betabound:
	m->mark.min_cost = costf(m, Sc_min + Sp_min);
	m->mark.max_cost = costf(m, Sc_max + Sp_max);
	dv("%s: min cost=%f (S=%f+%f) exceeded beta=%f\n",
			ddescm(s, m),
			m->mark.min_cost,
			Sc_min, Sp_min,
			beta
	);
}

static void mm_solve_value(struct state *s, struct fhk_var *y){
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

	exec_chain(s, y, y->mark.model);

	// TODO check invariants/retvalchecks (?)
}

static void exec_chain(struct state *s, struct fhk_var *y, struct fhk_model *m){
	fhk_vbmap *bm = &VBMAP(s, y);

	if(bm->has_value)
		return;

	assert(bm->chain_selected);

	for(size_t i=0;i<m->n_param;i++){
		// this won't cause problems because the selected chain will never have a loop
		struct fhk_var *x = m->params[i];

		if(VBMAP(s, x).given)
			resolve_given(s, x);
		else
			exec_chain(s, x, x->mark.model);

		assert(VBMAP(s, x).has_value);
	}

	exec_model(s, y, m);

	bm->has_value = 1;
}

static void exec_model(struct state *s, struct fhk_var *y, struct fhk_model *m){
	union pvalue args[m->n_param];
	for(size_t i=0;i<m->n_param;i++)
		args[i] = m->params[i]->mark.value;

	if(s->G->model_exec(s->G, m->udata, &y->mark.value, args))
		FAIL(FHK_MODEL_FAILED, m, y);
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

static int check_cst(struct fhk_cst *cst, union pvalue v){
	switch(cst->type){

		case FHK_RIVAL:
			return v.r >= cst->rival.min && v.r <= cst->rival.max;

		case FHK_IIVAL:
			return v.i >= cst->iival.min && v.i <= cst->iival.max;

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

		resolve_given(s, x);

		if(VBMAP(s, x).has_value){
			double cost = c->costs[check_cst(&c->cst, x->mark.value)];
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

static void resolve_given(struct state *s, struct fhk_var *x){
	fhk_vbmap *bm = &VBMAP(s, x);

	if(bm->given && !bm->has_value){
		bm->has_value = 1;

		if(x->is_virtual){
			dv("Resolving virtual %s\n", ddescv(s, x));

			if(s->G->resolve_virtual(s->G, x->udata, &x->mark.value))
				FAIL(FHK_RESOLVE_FAILED, NULL, x);
		}
	}
}

static void param_bounds(double *Sp_min, double *Sp_max, struct fhk_model *m){
	double min = 0, max = 0;

	for(size_t i=0;i<m->n_param;i++){
		struct fhk_var *x = m->params[i];

		min += x->mark.min_cost;
		max += x->mark.max_cost;
	}

	*Sp_min = min;
	*Sp_max = max;
}

static void mmin2(struct fhk_model **m1, struct fhk_model **m2, struct fhk_var *y){
	assert(y->n_mod >= 2);

	struct fhk_model *a = y->models[y->models[0]->mark.min_cost >= y->models[1]->mark.min_cost];
	struct fhk_model *b = y->models[y->models[0]->mark.min_cost < y->models[1]->mark.min_cost];

	for(size_t i=2;i<y->n_mod;i++){
		struct fhk_model *m = y->models[i];

		if(m->mark.min_cost < b->mark.min_cost){
			if(m->mark.min_cost < a->mark.min_cost){
				b = a;
				a = m;
			}else{
				b = m;
			}
		}
	}

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
