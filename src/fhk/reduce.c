#include "fhk.h"
#include "graph.h"
#include "def.h"

#include "../def.h"
#include "../mem.h"

#include <stdint.h>
#include <stdbool.h>
#include <stdalign.h>
#include <string.h>
#include <math.h>
#include <x86intrin.h>
#include <setjmp.h>

// note: encoding the cost overflow here allows for free checks:
//     * in model: covf(p1+p2+...+pN) > 0    <=>    covf(p1) > 0 or ... or covf(pN) > 0
//     * in var  : min(covf(m1), ..., covf(mN)) = 0    <=>    covf(mi) = 0 for some i
typedef __m128 f2_128; // {low, high, covf (cost overflow), unused}
typedef union {
	__m64 m64; // {low, high}
	float f32[2];
} f2_64;

#define f2_128_load64(p)    _mm_loadl_pi(_mm_setzero_ps(), (__m64 *) (p))
#define f2_128_store64(p,x) _mm_storel_pi((__m64 *) (p), (x))
#define f2_128_(...)        (__m128){__VA_ARGS__}

// doesn't matter what this is as long as it's negative
#define COST_OVERFLOW (-INFINITY)

#define low(x)      (x)[0]
#define high(x)     (x)[1]
#define covf(x)     (x)[2]
#define has_covf(x) (covf(x) == COST_OVERFLOW)

#define is_nonempty(map) (FHK_MAP_TAG(map) != FHK_MAP_TAG(FHKM_USER))

struct vstate {
	bool given;
	bool mark;
	bool done;
	bool selected;
	f2_64 bound;
};

struct mstate {
	bool done;
	bool selected;
	f2_64 bound;
};

struct fhk_reducer {
	arena *arena;
	struct fhk_graph G;
	struct fhk_subgraph sub;
	struct vstate *v_ss;
	struct mstate *m_ss;
	uint16_t s_nv, s_nm, s_nu;
	jmp_buf jmp_fail;
};

static struct fhk_reducer *r_create(struct fhk_graph *G, arena *arena);

static float r_searchv_root(struct fhk_reducer *restrict R, f2_64 *mbound, xidx xi);
static f2_128 r_searchv(struct fhk_reducer *restrict R, xidx xi, float beta);
static f2_128 r_searchm(struct fhk_reducer *restrict R, xidx mi, float beta);

static void r_selectv(struct fhk_reducer *restrict R, xidx xi);
static void r_selectm(struct fhk_reducer *restrict R, xidx mi);

static void r_addv(struct fhk_reducer *R, xidx xi);
static void r_addm(struct fhk_reducer *R, xidx mi);

static void r_fail(struct fhk_reducer *R, xidx xi);

struct fhk_subgraph *fhk_reduce(struct fhk_graph *G, arena *arena, uint8_t *v_flags, uint16_t *fail){
	struct fhk_reducer *R = r_create(G, arena);

	uint16_t fxi;
	if(UNLIKELY(fxi = setjmp(R->jmp_fail))){
		if(fail)
			*fail = ~fxi;
		return NULL;
	}

	size_t nv = G->nv;

	for(size_t i=0;i<nv;i++){
		if(v_flags[i] & FHKR_GIVEN)
			R->v_ss[i].given = true;
	}

	for(size_t i=0;i<nv;i++){
		if(v_flags[i] & FHKR_ROOT)
			r_selectv(R, i);
	}

	return &R->sub;
}

static struct fhk_reducer *r_create(struct fhk_graph *G, arena *arena){
	struct fhk_reducer *R = arena_malloc(arena, sizeof(*R));
	R->G = *G;
	R->arena = arena;

	R->s_nv = 0;
	R->s_nm = 0;
	R->s_nu = 0;

	R->sub.r_vars = arena_alloc(arena, G->nv * sizeof(*R->sub.r_vars), alignof(*R->sub.r_vars));
	R->sub.r_models = arena_alloc(arena, G->nm * sizeof(*R->sub.r_models), alignof(*R->sub.r_models));

	R->v_ss = arena_alloc(arena, G->nv * sizeof(*R->v_ss), alignof(*R->v_ss));
	R->m_ss = arena_alloc(arena, G->nm * sizeof(*R->m_ss), alignof(*R->m_ss));

	// 0xffff -> skip
	memset(R->sub.r_vars, 0xff, G->nv*sizeof(*R->sub.r_vars));
	memset(R->sub.r_models, 0xff, G->nm*sizeof(*R->sub.r_models));
	memset(R->v_ss, 0, G->nv*sizeof(*R->v_ss));
	memset(R->m_ss, 0, G->nm*sizeof(*R->m_ss));

	return R;
}

// this is like r_searchv, but:
// * the variable can't be given
// * return beta instead of bound
// * store model bounds
//     note: this is not equivalent to running r_searchm then reading the stored bound.
//           the bound will depend on the chain if the graph has cycles.
static float r_searchv_root(struct fhk_reducer *restrict R, f2_64 *mbound, xidx xi){
	// do NOT call this recursively

	struct fhk_var *x = &R->G.vars[xi];
	struct vstate *vs = &R->v_ss[xi];
	vs->mark = true;

	f2_128 bound = f2_128_(INFINITY, INFINITY);

	for(size_t i=0;i<x->n_mod;i++){
		fhk_edge e = x->models[i];
		f2_128 mb = r_searchm(R, e.idx, high(bound));

		// see comment in r_searchv
		if(!is_nonempty(e.map))
			high(mb) = INFINITY;

		bound = _mm_min_ps(bound, mb);
		f2_128_store64(&mbound[i], mb);

		// models with a single return that hit a cycle could be marked done here,
		// however that's a waste because they can only be reached through this var and
		// this var will be marked.
		// other models can't be marked because they might have better chains when reached
		// from another variable.
	}

	vs->mark = false;

	dv("%s -- root bound [%f, %f]%s\n", fhk_Dvar(&R->G, xi), low(bound), high(bound),
			has_covf(bound) ? " (COVF)" : "");

	// the only paths that have been excluded now are those that contain unavoidable cycles,
	// we can't do any better for this variable, so declare it as done regardless of pruning.

	// this works even if the var was already done:
	// * if its non-cyclic we are just writing the same bound back.
	// * if its cyclic, the non-cyclic path always has a lower cost than the cyclic one,
	//   so using the computed cyclic paths doesn't matter, the minimum will stay the same.
	
	assert(!vs->done || (low(vs->bound.f32) == low(bound) && high(vs->bound.f32) == high(bound)));
	
	vs->done = true;
	f2_128_store64(&vs->bound, bound);

	return high(bound);
}

// find a [min, max] bound such that min <= cost(v) <= max for a variable v
//
// the algorithm (without caching/pruning):
//
// search_var(v):
//     if v.given: return [0, 0]
//     if v.mark:  return [inf, inf]
//
//     v.mark <- true
//     cost <- min(costf(m, sum(search_var(x) : x of m.parameters)) : m of v.models, m->v is a simple edge)
//     v.mark <- false
//     return cost
//
// notes:
//     * if the min bound becomes too high, the chain can be pruned, it won't be selected in the
//       subgraph
//     * if the search (for an edge) finishes without any prunes (including from cycles), it
//       won't need to be revisited again, the bound can be stored
//         -> this will handle chains which have min=inf the same as cycles, ie. revisiting them,
//            but min=inf cycles should never happen (only way this can happen is a model has k=inf)
static f2_128 r_searchv(struct fhk_reducer *restrict R, xidx xi, float beta){
	struct vstate *vs = &R->v_ss[xi];

	if(vs->done)
		return f2_128_load64(&vs->bound);

	if(vs->given)
		return f2_128_(0, 0);

	if(UNLIKELY(vs->mark)){
		dv("%s -- cycle\n", fhk_Dvar(&R->G, xi));
		return f2_128_(INFINITY, INFINITY, COST_OVERFLOW);
	}

	if(UNLIKELY(beta <= 0))
		return f2_128_(0, INFINITY, COST_OVERFLOW);

	vs->mark = true;
	struct fhk_var *x = &R->G.vars[xi];

	f2_128 bound = f2_128_(INFINITY, INFINITY);

	// x may have 0 models here even though it is not given
	for(size_t i=0;i<x->n_mod;i++){
		fhk_edge e = x->models[i];
		f2_128 mb = r_searchm(R, e.idx, beta);

		// if model set is empty then cost=inf
		if(!is_nonempty(e.map))
			high(mb) = INFINITY;

		bound = _mm_min_ps(bound, mb);
		beta = min(beta, high(mb));
	}

	vs->mark = false;
	dv("%s -- bound [%f, %f]%s beta=%f\n", fhk_Dvar(&R->G, xi), low(bound), high(bound),
			has_covf(bound) ? " (COVF)" : "", beta);

	// no model hit bound, no path needs revisit
	if(!has_covf(bound)){
		vs->done = true;
		f2_128_store64(&vs->bound, bound);
	}

	return bound;
}

static f2_128 r_searchm(struct fhk_reducer *restrict R, xidx mi, float beta){
	struct mstate *ms = &R->m_ss[mi];

	if(ms->done)
		return f2_128_load64(&ms->bound);

	struct fhk_model *m = &R->G.models[mi];
	float beta_S = costf_invS(m, beta);

	if(beta_S <= 0){
		dv("%s -- k>=beta : %f >= %f\n", fhk_Dmodel(&R->G, mi), m->k, beta);
		return f2_128_(m->k, INFINITY, COST_OVERFLOW);
	}

	f2_128 bound_S = f2_128_(0, 0);

	// this doesn't need a cycle detection mark: if it has a cycle then some parameter will
	// detect it and return [inf, inf]

	// Note: must loop over all params and not cparams here, as given variables may be different
	for(size_t i=0;i<m->n_param;i++){
		fhk_edge e = m->params[i];
		f2_128 xb = r_searchv(R, e.idx, beta_S - low(bound_S));

		// arbitrary maps may contain empty sets here, which makes the param cost 0
		// (TODO? allow user to set a NONEMPTY hint)
		if(!is_nonempty(e.map))
			low(xb) = 0;

		bound_S += xb;

		// may or may not COST_OVERFLOW (eg. if a parameter cost is constant infinity, then
		// low(bound_S)=infinity without overflow)
		if(low(bound_S) >= beta_S)
			break;
	}

	f2_128 bound = costf(m, bound_S);

	if(!has_covf(bound_S)){
		// no need to care about the check chains now, the cost doesn't matter
		// later if this model is chosen, we will make best effort to include the check vars
		// as search roots
		float S_check = 0;
		for(size_t i=0;i<m->n_check;i++)
			S_check += m->checks[i].cst.penalty;

		high(bound) += m->c * S_check;
		ms->done = true;
		f2_128_store64(&ms->bound, bound);
	}

	dv("%s -- bound [%f, %f]%s beta=%f\n", fhk_Dmodel(&R->G, mi), low(bound), high(bound),
			has_covf(bound) ? " (COVF)" : "", beta);

	// costf preserves overflow
	return bound;
}

static void r_selectv(struct fhk_reducer *restrict R, xidx xi){
	struct vstate *vs = &R->v_ss[xi];

	if(vs->selected)
		return;

	dv("%s -- select variable\n", fhk_Dvar(&R->G, xi));

	vs->selected = true;
	r_addv(R, xi);

	if(R->v_ss[xi].given)
		return;

	// model selection:
	// (1) let beta = min(high(m.bound) : m in x.models)
	//     - beta must exist (nongiven variable), and should generally be finite, see [*]
	// (2) pick all models {m : low(m.bound) < beta}
	// (3) if none of the models in (2) has high(m.bound) = beta, then pick one (doesn't matter which)
	//     with high(m.bound)=beta. this ensures that we keep the optimal bound while pruning
	//     models that the solver will never pick
	//
	// this also works for cyclic graphs (ie. it will not prune cycles "too aggressively").
	// if we have the cycle x <--> y, then due to the non-decreasingness of the cost function,
	//     * x->y implies cost(y) >= cost(x)
	//     * y->x implies cost(x) >= cost(y),
	// so the selector can't prune non-cyclic chains for both, as that would make
	// cost(x)=cost(y)=inf.
	//
	// after model selection, recursively pick parameters and checks for each model.
	//
	// [*] if beta is infinite, then all models have low(m.bound)=inf, so we just pick one of
	// them. this model can never be picked by the solver algorithm, but x must have a model so
	// that it doesn't become given when the user intends it to be nongiven. the case beta=inf
	// is probably an user error but not technically invalid so the subgraph picker algorithm
	// will not complain.
	
	// (1)
	struct fhk_var *x = &R->G.vars[xi];

	if(UNLIKELY(V_GIVEN(x))){
		// we would need to include a given variable that's not given in the subgraph.
		// this would produce an invalid graph, so we stop.
		dv("%s -- would pick this but it's not given and has no models. failing.\n", fhk_Dvar(&R->G, xi));
		r_fail(R, xi);
	}

	f2_64 bounds[x->n_mod];
	float beta = r_searchv_root(R, bounds, xi);
	bool havemin = false;

	dv("%s -- picking all models below %f\n", fhk_Dvar(&R->G, xi), beta);

	// (2)
	size_t i = 0;
	do {
		if(low(bounds[i].f32) < beta){
			havemin |= high(bounds[i].f32) == beta;
			fhk_edge e = x->models[i];
			r_selectm(R, e.idx);
		}
	} while(++i < x->n_mod);

	// (3)
	if(havemin)
		return;

	dv("%s -- min model not intially chosen, choosing low=%f\n", fhk_Dvar(&R->G, xi), beta);

	i = 0;
	do {
		// the remaining model must have low = high = beta
		if(low(bounds[i].f32) == beta){
			assert(high(bounds[i].f32) == beta);
			fhk_edge e = x->models[i];
			r_selectm(R, e.idx);
			return;
		}
	} while(++i < x->n_mod);

	assert(!"inconsistent state");
	__builtin_unreachable();
}

static void r_selectm(struct fhk_reducer *restrict R, xidx mi){
	struct mstate *ms = &R->m_ss[mi];

	if(ms->selected)
		return;

	dv("%s -- select model\n", fhk_Dmodel(&R->G, mi));

	ms->selected = true;
	r_addm(R, mi);

	struct fhk_model *m = &R->G.models[mi];

	for(size_t i=0;i<m->n_param;i++){
		fhk_edge e = m->params[i];
		r_selectv(R, e.idx);
	}

	for(size_t i=0;i<m->n_check;i++){
		fhk_edge e = m->checks[i].edge;
		r_selectv(R, e.idx);
	}

	// this loop guarantees that:
	// * no return value of a model is given
	// * all return values of an included model will be included
	//
	// this allows the solver to work with the definition that given <=> no models.
	// all returns should be included so that the caller doesn't need to do filtering
	// before copying the return values to solver memory (and in 99% of cases you really
	// want -- or at least can't prove that you don't want -- all return values).
	//
	// note that this will not force chain selection for the returns. this is ok
	// because if there is any possibility that a result is needed then it will have
	// a chain selected later.
	//
	// imo, this is not a bug/problem of the solver. the user is telling the solver that
	// (say) x is given, but also that it should try to compute x using (say) M.
	// the "workaround" is make a version of the model that returns only the computed
	// variables. this is also the faster (in the computational sense) than special-casing
	// one-way return-edges in the solver or model caller.
	for(size_t i=0;i<m->n_return;i++){
		fhk_edge e = m->returns[i];
		if(R->v_ss[e.idx].given){
			dv("%s -- given variable but computing model included in graph: %s. failing.\n",
					fhk_Dvar(&R->G, e.idx), fhk_Dmodel(&R->G, mi));
			r_fail(R, e.idx);
		}
		r_addv(R, e.idx);
	}
}

static void r_addv(struct fhk_reducer *R, xidx xi){
	if(LIKELY(R->sub.r_vars[xi] == FHKR_SKIP))
		R->sub.r_vars[xi] = R->s_nv++;
}

static void r_addm(struct fhk_reducer *R, xidx mi){
	if(LIKELY(R->sub.r_models[mi] == FHKR_SKIP))
		R->sub.r_models[mi] = R->s_nm++;
}

static void r_fail(struct fhk_reducer *R, xidx xi){
	longjmp(R->jmp_fail, ~xi);
}
