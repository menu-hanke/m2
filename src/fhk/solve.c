#include "fhk.h"
#include "graph.h"
#include "def.h"
#include "coro.h"

#include "../def.h"
#include "../mem.h"

#include <stdint.h>
#include <stdalign.h>
#include <stdbool.h>
#include <string.h>
#include <alloca.h>
#include <assert.h>
#include <math.h>
#include <float.h>

// maximum cost, anything above this will not be accepted.
// this should be relatively low such that rounding error will not cause problems, but high
// enough that real chains won't get cancelled.
// Note: don't put this above 2^24 (~16 million), after that integers aren't representable
// anymore
#define MAX_COST 1000000

// status values
#define S_A(x)      (((uint64_t)(x)) << 48)
#define S_B(x)      (((uint64_t)(x)) << 32)
#define S_C(x)      (((uint64_t)(x)) << 16)
#define S_ABC       S_C
#define STATUS(...) ((fhk_status){{__VA_ARGS__}})

// empty context marker
#define EMPTY ((int16_t)0xffff)

// subset and iterator representation
//                                   exclusive   inclusive
//                                      vvvvvv   vvvvv
//                    63..48   47..32   31..16   15..0
// simple subset      1                 end      start
// complex subset     n (>1)   ---pointer to ranges---
// subset iterator    n                 end      index
// fast singleton     1                 0        index
// empty ss/iter      0        0        0        0
// note: only representation allowed for an empty set is the canonical representation, 0
// note: technically fast singleton can use n=0, but then the set {0} has the same representation
//       as the empty set
typedef int64_t ss_iter;

#define SS_NUM(x)      ((uint64_t)((x) >> 48))
#define SS_END(x)      ((uint64_t)(((x) >> 16) & 0xffff))
#define SS_INDEX(x)    ((uint64_t)((x) & 0xffff))
#define RANGE_LEN(x)   (SS_END(x) - SS_INDEX(x))
#define SS_POINTER(x)  ((uint32_t *) ((x) & 0xffffffffffff))
#define SS_ITER(n,e,i) ((ss_iter)((((uint64_t)(n))<<48) | ((e)<<16) | (i)))
#define SS_EMPTY_ITER  0

// state representation:
//     vars:
//         searching -> cost = SP_MARK    state: 0
//         no chain  -> cost >= 0         state: 0
//         chain nv  -> cost >= 0         state: SP_CHAIN | chain info
//         chain v   -> cost >= 0         state: SP_CHAIN | SP_VALUE
//
//     models:
//         no chain  -> cost >= 0         state: 0
//         chain nv  -> cost >= 0         state: SP_CHAIN
//         chain v   -> cost >= 0         state: SP_CHAIN | SP_VALUE
typedef union {
	struct {
		// don't change the order of these fields, the macros below rely on it
		float cost;
		uint32_t state;
	};
	uint64_t u64;
} ssp;

#define SP_CHAIN              (1ULL << 31)
#define SP_VALUE              (1ULL << 30)
#define SP_CHAIN_V(e,i)       (SP_CHAIN|((e)<<16)|(i))
#define SP_CHAIN_EI(sp)       (((sp).state >> 16) & 0xff)
#define SP_CHAIN_INSTANCE(sp) ((sp).state & 0xffff)

#define FP_INFINITY   0x7f800000ULL
#define FP_SIGN       0x80000000ULL
#define SP_DONE(sp)   (((sp).u64 & ~FP_SIGN) >= FP_INFINITY)
#define SP_MARK       ((union { uint32_t u32; float f; }){.u32=0x80800000}).f
#define SP_MARKED(sp) ((sp).cost < 0)

#define GS_ALL        ((uint64_t *)(~0))

typedef struct {
	// TODO: if it can be deduced that all vars in a group have the same cost and chain,
	// put it here and don't allocate sp at all

	union {
		// for non-given variables: the search state
		ssp *sp;

		// for given variables: given status
		//     NULL      -> not allocated
		//     GS_ALL    -> all given (special case)
		//     otherwise -> bitmap with bits set for given instances 
		uint64_t *gs;
	};

	void *vp;
} S_var;

typedef struct {
	ssp *sp;
	void **retbuf;
} S_model;

typedef uint32_t sc_mask;
typedef uint64_t sc_mem;
#define MAX_SCRATCH       (8*sizeof(sc_mask))
#define SC_MIN_ALLOC      512
#define SC_MEM(ptr, size) ({ assert((size) <= 0xffff); (((uintptr_t)(ptr) << 48) | (size)); })
#define SC_MEM_PTR(sm)    ((void *)((sm) >> 48))
#define SC_MEM_SIZE(sm)   ((sm) & 0xffff)

#define UMAP_NONE (~0)

struct fhk_solver {
	struct fhk_graph G;
	arena *arena;
	fhk_co *co;

	// request
	size_t r_nv;
	struct fhk_req *r_req;

	// search state
	S_var *vars;
	S_model *models;

	// shape table (not preallocated)
	int16_t *g_shape;

	// subset map & inverse cache
	fhk_subset **u_map;
	fhk_subset **u_inverse;

	// scratch mem buffers
	sc_mask sc_free;
	sc_mem sc_mem[MAX_SCRATCH];
};

// J_* functions jump out of the solver
// only call from inside the solver coroutine
#define J_yield(S,s) fhk_co_yield((S)->co, s)
static void J_error(struct fhk_solver *S, int err, int flags, struct fhk_ei *ei);
#define J_fail(S,code,why,flags,...) do {                                \
		dv("solver failed here: %s:%d (" why ")\n", __func__, __LINE__); \
		struct fhk_ei *_ei = neweinfo(S);                                \
		*_ei = (struct fhk_ei){.desc=why, ##__VA_ARGS__};                \
		J_error(S,code,flags,_ei);                                       \
	} while(0)
#define J_nyi(S,why) J_fail(S, FHKE_NYI, "NYI: " why, 0)

// S_* functions (solver functions) must be also called from the solver coroutine
// (these may call J_* functions)
static void S_solve_co();
static void S_solve(struct fhk_solver *restrict S);
static size_t S_shape(struct fhk_solver *restrict S, size_t group);

// TODO: it would be a nice optimization to have these functions return ss_iter directly
// and not carry around `subset` at all.
// (this still requires carrying around the range pointer for complex subsets)
static fhk_subset S_map(struct fhk_solver *restrict S, xmap map, xinst inst);
static fhk_subset S_umap(struct fhk_solver *restrict S, xmap map, xinst inst);

static ssp *S_var_ssp(struct fhk_solver *restrict S, xidx xi);
static void *S_var_vp(struct fhk_solver *restrict S, xidx xi);
static uint64_t *S_var_gs(struct fhk_solver *restrict S, xidx xi);
static ssp *S_model_ssp(struct fhk_solver *restrict S, xidx mi);
static void **S_model_retbuf(struct fhk_solver *restrict S, xidx mi, xinst inst);

static void *S_scratch_acquire(struct fhk_solver *restrict S, sc_mask *mask, size_t size);
static void S_scratch_release(struct fhk_solver *restrict S, sc_mask mask);

static void S_select_chain_ssne(struct fhk_solver *restrict S, xidx xi, fhk_subset ss);
static void S_select_chain(struct fhk_solver *restrict S, xidx xi, xinst xinst);
static void S_mcand(struct fhk_solver *restrict S, unsigned *m_ei, xinst *m_inst, float *m_cost,
		float *m_beta, struct fhk_var *x, xinst x_inst);
static bool S_check_ssne(struct fhk_solver *restrict S, int op, fhk_arg arg, xidx xi,
		fhk_subset ss);
static void S_get_given_ssne(struct fhk_solver *restrict S, xidx xi, fhk_subset ss);
static void S_compute_value(struct fhk_solver *restrict S, xidx xi, xinst inst, ssp *sp);
static void S_get_computed_ssne(struct fhk_solver *restrict S, xidx xi, fhk_subset ss);
static void S_get_value_ssne(struct fhk_solver *restrict S, xidx xi, fhk_subset ss);
static void S_compute_model(struct fhk_solver *restrict S, xidx mi, xinst inst, ssp *sp);
static void S_collect_ssne(struct fhk_solver *restrict S, void **p, size_t *num, sc_mask *sc_used,
		xidx xi, fhk_subset ss);

static struct fhk_ei *neweinfo(struct fhk_solver *S);
#define STATUS_E(S,code,why,flags,...) ({                                       \
		dv("solver control error here: %s:%d (" why ")\n", __func__, __LINE__); \
		struct fhk_ei *_ei = neweinfo(S);                                       \
		*_ei = (struct fhk_ei){.desc=why, ##__VA_ARGS__};                       \
		STATUS(FHK_ERROR | S_A(code) | S_B(flags), (uint64_t)_ei);              \
	})

static ss_iter ss_first(fhk_subset ss);
static ss_iter ss_first_nonempty(fhk_subset ss);
static ss_iter ss_next(fhk_subset ss, ss_iter it);
static size_t ss_size_nonempty(fhk_subset ss);
static size_t ss_complex_size(fhk_subset ss);
static void ss_complex_collect(void *dest, void *src, size_t sz, fhk_subset ss);
static void ss_collect(void *dest, void *src, size_t sz, fhk_subset ss);
static size_t ss_complex_size(fhk_subset ss);
static bool ss_contains(fhk_subset ss, xinst inst);
static size_t ss_indexof(fhk_subset ss, xinst inst);

static ssp *ssp_alloc(struct fhk_solver *S, size_t n, ssp init);

static void bm_set(uint64_t *b, xinst inst);
static bool bm_isset(uint64_t *b, xinst inst);
static bool bm_find0_range(uint64_t *b, xinst *inst, xinst from, xinst to);
static bool bm_find0_ssne(uint64_t *b, xinst *inst, fhk_subset ss);

fhk_solver *fhk_create_solver(struct fhk_graph *G, arena *arena, size_t nv, struct fhk_req *req){
	fhk_co_thread_init();

	struct fhk_solver *S = arena_malloc(arena, sizeof(*S));
	S->G = *G;
	S->arena = arena;
	S->co = fhk_co_create(&S_solve_co, S);

	S->vars = arena_malloc(arena, G->nv * sizeof(*S->vars));
	S->models = arena_malloc(arena, G->nm * sizeof(*S->models));
	S->u_map = arena_malloc(arena, G->nu * sizeof(*S->u_map));
	S->u_inverse = arena_malloc(arena, G->nu * sizeof(*S->u_inverse));
	memset(S->vars, 0, G->nv*sizeof(*S->vars));
	memset(S->models, 0, G->nm*sizeof(*S->models));
	memset(S->u_map, 0, G->nu*sizeof(*S->u_map));
	memset(S->u_inverse, 0, G->nu*sizeof(*S->u_inverse));

	S->g_shape = NULL;

	S->sc_free = ~0;
	for(size_t i=0;i<MAX_SCRATCH;i++)
		S->sc_mem[i] = SC_MEM(NULL, 0xffff);

	S->r_nv = nv;
	S->r_req = arena_malloc(arena, nv * sizeof(*S->r_req));
	memcpy(S->r_req, req, nv * sizeof(*S->r_req));

	return S;
}

fhk_status fhk_continue(struct fhk_solver *S){
	return fhk_co_resume(S->co);
}

fhk_status fhkS_shape(struct fhk_solver *S, size_t group, int16_t shape){
	if(UNLIKELY(group >= S->G.ng))
		return STATUS_E(S, FHKE_INVAL, "shape table group out of bounds", FHKEI_G, .g=group);

	if(UNLIKELY(!S->g_shape)){
		S->g_shape = arena_alloc(S->arena, S->G.ng * sizeof(*S->g_shape), alignof(*S->g_shape));
		memset(S->g_shape, 0xff, S->G.ng * sizeof(*S->g_shape));
	}

	if(UNLIKELY(S->g_shape[group] != EMPTY))
		return STATUS_E(S, FHKE_INVAL, "attempt to overwrite shape table entry", FHKEI_G, .g=group);

	dv("shape[%zu] -> %d\n", group, shape);
	S->g_shape[group] = shape;
	return STATUS(FHK_OK);
}

fhk_status fhkS_shape_table(struct fhk_solver *S, int16_t *shape){
	if(UNLIKELY(S->g_shape))
		return STATUS_E(S, FHKE_INVAL, "attempt to overwrite shape table", 0);

	dv("shape table -> %p\n", shape);
	S->g_shape = shape;
	return STATUS(FHK_OK);
}

fhk_status fhkS_give(struct fhk_solver *S, size_t xi, size_t inst, void *vp){
	struct fhk_var *x = &S->G.vars[xi];
	if(UNLIKELY(!V_GIVEN(x)))
		return STATUS_E(S, FHKE_INVAL, "attempt to give non-given variable", FHKEI_V|FHKEI_I,
				.v=xi, .i=inst);

	if(UNLIKELY(!S->g_shape || S->g_shape[x->group] == EMPTY))
		return STATUS(FHKS_SHAPE, x->group);

	if(UNLIKELY(inst >= (size_t)S->g_shape[x->group]))
		return STATUS_E(S, FHKE_INVAL, "instance out of bounds", FHKEI_V|FHKEI_I,
				.v=xi, .i=inst);

	// this can't yield now because we have the shape
	bm_set(S_var_gs(S, xi), inst);
	memcpy(S_var_vp(S, xi)+inst*x->size, vp, x->size);

	return STATUS(FHK_OK);
}

fhk_status fhkS_give_all(struct fhk_solver *S, size_t xi, void *vp){
	if(UNLIKELY(!V_GIVEN(&S->G.vars[xi])))
		return STATUS_E(S, FHKE_INVAL, "attempt to give non-given variable", FHKEI_V, .v=xi);

	if(UNLIKELY(S->vars[xi].gs))
		return STATUS_E(S, FHKE_INVAL, "attempt to overwrite partially given variable", FHKEI_V, .v=xi);

	assert(!S->vars[xi].vp);

	S->vars[xi].gs = GS_ALL;
	S->vars[xi].vp = vp;

	dv("%s -- given buffer @ %p\n", fhk_Dvar(&S->G, xi), vp);

	return STATUS(FHK_OK);
}

fhk_status fhkS_use_mem(struct fhk_solver *S, size_t xi, void *vp){
	if(UNLIKELY(S->vars[xi].vp))
		return STATUS_E(S, FHKE_INVAL, "attempt to overwrite allocated buffer", FHKEI_V, .v=xi);

	S->vars[xi].vp = vp;

	return STATUS(FHK_OK);
}

__attribute__((cold,noreturn))
static void J_error(struct fhk_solver *S, int err, int flags, struct fhk_ei *ei){
	for(;;)
		J_yield(S, STATUS(FHK_ERROR | S_A(err) | S_B(flags), (uintptr_t)ei));
}

static void S_solve_co(){
	struct fhk_solver *S = fhk_co_arg();
	S_solve(S);

	for(;;)
		J_yield(S, STATUS(FHK_OK));
}

// the use of restrict is valid here because modifying the graph/solver is not allowed
// this basically tells the compiler that user callbacks won't touch S
// (unfortunately there's no way to tell the compiler S won't be written to at all,
// but this still enables some optimizations on clang)
static void S_solve(struct fhk_solver *restrict S){
	for(size_t i=0;i<S->r_nv;i++){
		struct fhk_req r = S->r_req[i];

		if(UNLIKELY(!r.ss))
			continue;

		S_select_chain_ssne(S, r.idx, r.ss);
	}

	for(size_t i=0;i<S->r_nv;i++){
		struct fhk_req r = S->r_req[i];

		if(UNLIKELY(!r.ss))
			continue;

		S_get_value_ssne(S, r.idx, r.ss);

		if(r.buf)
			ss_collect(r.buf, S->vars[r.idx].vp, S->G.vars[r.idx].size, r.ss);
	}
}

// this will be inlined, but clang still can use the knowledge that this doesn't have side effects
// (gcc can't)
__attribute__((pure))
static size_t S_shape(struct fhk_solver *restrict S, size_t group){
	if(UNLIKELY(!S->g_shape || S->g_shape[group] == EMPTY)){
		J_yield(S, STATUS(FHKS_SHAPE, group));

		if(UNLIKELY(!S->g_shape || S->g_shape[group] == EMPTY))
			J_fail(S, FHKE_INVAL, "missing shape table entry", FHKEI_G, .g=group);
	}

	return S->g_shape[group];
}

#ifdef FHK_DEBUG

#endif

static fhk_subset S_map(struct fhk_solver *restrict S, xmap map, xinst inst){
	switch(MAP_TAG(map)){
		case FHK_MAP_USER: return S_umap(S, map, inst);
		case FHK_MAP_IDENT: return SS_ITER(1, 0, inst);
		case FHK_MAP_SPACE: { size_t s = S_shape(S, map & 0xffff); return SS_ITER(!!s, s, 0); }
		case FHK_MAP_RANGE: assert(!"TODO");
	}

	__builtin_unreachable();
}

static fhk_subset S_umap(struct fhk_solver *restrict S, xmap map, xinst inst){
	fhk_subset **cache = (map & UMAP_INVERSE) ? S->u_inverse : S->u_map;
	fhk_subset *cm = cache[map & UMAP_INDEX];

	if(UNLIKELY(!cm)){
		size_t shape = S_shape(S, S->G.umaps[map & UMAP_INDEX].group[!!(map & UMAP_INVERSE)]);
		cm = cache[map & UMAP_INDEX] = arena_malloc(S->arena, shape * sizeof(*cm));
		memset(cm, 0xff, shape * sizeof(*cm));
	}

	if(LIKELY(cm[inst] != UMAP_NONE))
		return cm[inst];

	struct fhks_mapping mp = {
		.instance = inst,
		.ss = &cm[inst]
	};

	uint64_t udata = S->G.umaps[map & UMAP_INDEX].udata.u64;
	J_yield(S, STATUS((FHKS_MAPPING+!!(map & UMAP_INVERSE)) | S_ABC(&mp), udata));

	if(UNLIKELY(cm[inst] == UMAP_NONE))
		J_fail(S, FHKE_VALUE, "requested mapping not given", 0);

	dv("umap %c%d:%zu -> 0x%lx\n", (map & UMAP_INVERSE) ? '<' : '>', map & UMAP_INDEX,
			inst, cm[inst]);

	return cm[inst];
}

static ssp *S_var_ssp(struct fhk_solver *restrict S, xidx xi){
	assert(V_COMPUTED(&S->G.vars[xi]));

	ssp *vs = S->vars[xi].sp;
	if(LIKELY(vs))
		return vs;

	return S->vars[xi].sp = ssp_alloc(S, S_shape(S, S->G.vars[xi].group), (ssp){.cost=0, .state=0});
}

static void *S_var_vp(struct fhk_solver *restrict S, xidx xi){
	void *vp = S->vars[xi].vp;
	if(LIKELY(vp))
		return vp;

	struct fhk_var *x = &S->G.vars[xi];
	size_t size = x->size;
	size_t n = S_shape(S, x->group);
	return S->vars[xi].vp = arena_alloc(S->arena, n*size, size);
}

static uint64_t *S_var_gs(struct fhk_solver *restrict S, xidx xi){
	assert(V_GIVEN(&S->G.vars[xi]));

	uint64_t *gs = S->vars[xi].gs;
	if(LIKELY(gs))
		return gs;

	size_t sz = 8 * (S_shape(S, S->G.vars[xi].group) + 7) / 8; // align to next 8 multiple
	gs = arena_malloc(S->arena, sz);
	memset(gs, 0, sz);
	return S->vars[xi].gs = gs;
}

static ssp *S_model_ssp(struct fhk_solver *restrict S, xidx mi){
	ssp *ms = S->models[mi].sp;
	if(LIKELY(ms))
		return ms;

	// TODO: `k` is used here for init cost bound, but preprocess should compute a better bound
	struct fhk_model *m = &S->G.models[mi];
	return S->models[mi].sp = ssp_alloc(S, S_shape(S, m->group), (ssp){.cost=m->k, .state=0});
}

static void **S_model_retbuf(struct fhk_solver *restrict S, xidx mi, xinst inst){
	struct fhk_model *m = &S->G.models[mi];

	// don't call this on models that don't need a retbuf
	assert(!(m->flags & M_NORETBUF));

	void **b = S->models[mi].retbuf;
	if(UNLIKELY(!b)){
		size_t n = S_shape(S, m->group);
		b = S->models[mi].retbuf = arena_malloc(S->arena, m->n_return * n * sizeof(void *));
	}

	return b + (inst * m->n_return);
}

static void *S_scratch_acquire(struct fhk_solver *restrict S, sc_mask *mask, size_t size){
	sc_mask sc_free = S->sc_free;
	sc_mem *scm = S->sc_mem;

	if(UNLIKELY(!sc_free))
		J_fail(S, FHKE_MEM, "all scratch buffers in use", 0);

	size_t idx;

	while(sc_free){
		idx = __builtin_ctz(sc_free); // index of lsb (first free slot)
		sc_free = sc_free & (-sc_free); // clear lsb
		sc_mem m = scm[idx];

		if(LIKELY(SC_MEM_SIZE(m) >= size)){
			void *p = SC_MEM_PTR(m);
			if(UNLIKELY(!p))
				goto alloc;
			*mask |= 1ULL << idx;
			S->sc_free &= ~(1ULL << idx);
			return p;
		}
	}

	// no big enough free scratch buffer found, reallocate one that is free
	idx = __builtin_ctz(S->sc_free);

alloc:
	// make it a bit bigger to fit future allocations
	size *= 2;
	size = size < SC_MIN_ALLOC ? SC_MIN_ALLOC : size;

	void *p = arena_malloc(S->arena, size);
	scm[idx] = SC_MEM(p, size);
	*mask = 1ULL << idx;
	S->sc_free &= ~(1ULL << idx);
	return p;
}

static void S_scratch_release(struct fhk_solver *restrict S, sc_mask mask){
	assert(!(S->sc_free & mask));
	S->sc_free |= mask;
}

static void S_select_chain_ssne(struct fhk_solver *restrict S, xidx xi, fhk_subset ss){
	if(UNLIKELY(V_GIVEN(&S->G.vars[xi])))
		return;

	ssp *sp = S_var_ssp(S, xi);

	for(ss_iter it=ss_first_nonempty(ss); it; it=ss_next(ss, it)){
		xinst inst = SS_INDEX(it);
		if(!SP_DONE(sp[inst]))
			S_select_chain(S, xi, inst);
	}
}

// this is the main solver.
// in very rough pseudocode, it does the following:
//
//     select-var(xi, xinst):
//         if xi.cost:
//             return
//         for model m of xi.models:
//             S <- 0
//             for constraint c of m.constraints:
//                 select-var(c.var)
//                 compute-chain(c.var)
//                 S <- S + penalty(c)
//             for var y of m.parameters:
//                 select-var(y)
//                 S <- S + y.cost
//             m.cost <- m.costf(S)
//         xi.cost  <- min(m.cost : m in xi.models)
//         xi.chain <- argmin(...)
//
#pragma GCC diagnostic push
#if defined(__GNUC__) && !defined(__clang__)
// -Wmaybe-uninitilized gives false positives here because of the goto spaghetti hell
#pragma GCC diagnostic ignored "-Wmaybe-uninitialized"
#endif
static void S_select_chain(struct fhk_solver *restrict S, xidx x_i, xinst x_inst){
	// assumptions:
	//     * do NOT pass given variables here, check before calling if it's given.
	//       this function will access the search state which given variables DON'T have.
	//     * xi must be touched before (sp exists)
	
	// this is the "recursion" stack (see above pseudocode)
	typedef struct {
		xidx x_i;
		xinst x_inst;
		float beta;
		void *ret_fail, *ret_ok;

		unsigned m_ei;
		struct fhk_model *m;
		ssp *m_sp;
		float m_betaS, m_remS;
		xinst m_inst;

		union {
			struct {
				unsigned c_ei;
				fhk_subset c_ss;
				ss_iter c_ssit;
				ssp *c_sp;
				struct fhk_check *c;
			};
			struct {
				unsigned p_ei;
				fhk_subset p_ss;
				ss_iter p_ssit;
				ssp *p_sp;
				float p_ssmax;
			};
		};
	} frame;

#define MAX_STK 32

	frame _stk[MAX_STK];
	frame *top = &_stk[MAX_STK-1];

#define PUSH(ok, fail) do {\
		if(UNLIKELY(top == _stk))\
			J_fail(S, FHKE_DEPTH, "max recursion depth", 0);\
		top--;\
		top->ret_ok = (ok);\
		top->ret_fail = (fail);\
	} while(0)
#define POP()  do { top++; } while(0)
#define ISTOP() (top == &_stk[MAX_STK-1])

	top->ret_ok = &&done;
	top->ret_fail = &&fail;

	float beta = MAX_COST;
	float cost;

	// before jumping here, set:
	//     * xi, xinst : variable and instance to solve
	//     * beta      : max cost for chain
start:

	top->x_i = x_i;
	top->x_inst = x_inst;
	top->beta = beta;

	// cycle detection
	{
		ssp *sp = &S->vars[x_i].sp[x_inst];
		if(UNLIKELY(SP_MARKED(*sp)))
			J_nyi(S, "cycle");

		sp->cost = SP_MARK;
	}

	// model selection loop.
	// note that we want to recursively select chain, not only a single model.
	// even when there is only a single candidate, we must make sure that it has a full chain
	// selected.
	//                              this is because the cost check must have a strict inequality
	// algorithm roughly:           to prevent the solver from cycling between 2 equal cost models
	//                                                             |
	//     loop:                                                   |
	//         candidate <- model with lowest cost                 v
	//         beta      <- second lowest cost, or MAX_COST (note: NOT infinity) if only 1 model
	//         start solving checks and parameters of candidate:
	//             * if beta bound hit (cost > beta, STRICT inequality), goto loop
	//             * otherwise, we have a finite cost, chain is solved, select candidate
	for(;;){
		struct fhk_model *m;
		unsigned m_ei;
		xinst m_inst;
		float m_betaS, m_remS;
		ssp *m_sp;

		// select the candidate (set m, m_ei, m_inst, beta_S, rem_S)
		{
			float m_beta;
			struct fhk_var *x = &S->G.vars[x_i];
			S_mcand(S, &m_ei, &m_inst, &cost, &m_beta, x, x_inst);

			// lowest cost is too high?
			// this means that the _variable_ is now done, we couldn't find a good model
			if(UNLIKELY(cost > beta)){
				dv("%s:%zu -- no candidate with cost <= %f, lowest possible: %f\n",
						fhk_Dvar(&S->G, x_i), x_inst, beta, cost);

				// if best model was quit, there is nothing more we can do for this variable.
				// this will always clear the cycle mark because it's not set for models.
				S->vars[x_i].sp[x_inst].cost = cost;
				goto *top->ret_fail;
			}

			xidx mi = x->models[m_ei].idx;
			m_sp = &S->models[mi].sp[m_inst];
			m = &S->G.models[mi];
			m_betaS = costf_invS(m, min(m_beta, beta));

			dv("%s:%zu -- candidate %s:%zu (cost at least %f, accept if cost <= %f, S <= %f)\n",
					fhk_Dvar(&S->G, x_i), x_inst, fhk_Dmodel(&S->G, mi), m_inst, cost, m_beta, m_betaS);

			// this model already has a chain?
			// this means that the exact cost is known and below selection threshold, so there
			// is nothing to do
			if(UNLIKELY(m_sp->state & SP_CHAIN))
				goto choose;

			// intial cost
			float icostS = 0;

			// given, no gotos here!
			// check is after the loop because this loop isn't expensive
			// (usually, unless checking huge subsets)
			for(size_t c_ei=m->n_ccheck; c_ei<m->n_check; c_ei++){
				struct fhk_check *c = &m->checks[c_ei++];
				fhk_subset c_ss = S_map(S, c->edge.map, m_inst);

				if(UNLIKELY(!c_ss))
					continue;

				S_get_given_ssne(S, c->edge.idx, c_ss);
				if(S_check_ssne(S, c->op, c->arg, c->edge.idx, c_ss))
					continue;

				dv("%s:%zu -- given constraint violated for %s~0x%lx [+%f]\n",
						fhk_Dmodel(&S->G, mi), m_inst, fhk_Dvar(&S->G, c->edge.idx), c_ss, c->penalty);

				icostS += c->penalty;
			}

			if(icostS > m_betaS){
				m_sp->cost = costf(m, icostS);
				// don't need to `goto next` here - we never did recursion so all our variables
				// are correct
				dv("%s:%zu -- initial cost too high [%f]\n", fhk_Dmodel(&S->G, mi), m_inst, m_sp->cost);
				continue;
			}

			// m_remS = m_betaS - m_costS    <=>    m_costS = m_betaS - m_remS
			// candidate will be accepted iff
			//     m_costS <= m_betaS    <=>    m_remS >= 0
			// note that
			//     m_costS <- m_costS + x    <==>    m_remS <- m_remS - x
			//
			// XXX: this may not be a good idea because of rounding error, maybe should just
			// use m_costS instead
			m_remS = m_betaS - icostS;
		}

		// after this point we may need to do "recursion"

		top->m = m;
		top->m_ei = m_ei;
		top->m_inst = m_inst;
		top->m_betaS = m_betaS;
		top->m_remS = m_remS;
		top->m_sp = m_sp;

		// --------------- computed constraints -----------------

		if(UNLIKELY(m->n_ccheck > 0)){
			size_t c_ei = 0;

			do { // (m)
				struct fhk_check *c = &m->checks[c_ei++];
				fhk_subset c_ss = S_map(S, c->edge.map, top->m_inst);

				if(UNLIKELY(!c_ss))
					continue;

				x_i = c->edge.idx;
				ssp *c_sp = S_var_ssp(S, x_i);

				top->c_ei = c_ei;
				top->c_ss = c_ss;
				top->c_sp = c_sp;
				top->c = c;

				// first make sure the full subset has values
				// if even 1 has no value, we apply penalty
				ss_iter c_ssit = ss_first_nonempty(c_ss);
				do { // (c_ssit, c_sp)
					ssp *sp = &c_sp[SS_INDEX(c_ssit)];

					if(LIKELY(sp->state & SP_CHAIN)){
						if(UNLIKELY(!(sp->state & SP_VALUE)))
							S_compute_value(S, x_i, SS_INDEX(c_ssit), sp);
						c_ssit = ss_next(top->c_ss, c_ssit);
					}else if(UNLIKELY(sp->cost == INFINITY)){
						goto penalty;
					}else{
						// time to solve it
						top->c_ssit = c_ssit;
						beta = MAX_COST;
						x_inst = SS_INDEX(c_ssit);
						PUSH(&&check_return, &&check_fail);
						goto start;
check_return:
						POP();
						c_ssit = top->c_ssit;
						c_sp = top->c_sp;
						m = top->m;
						// it must have succeeded (otherwise we would go to check_fail),
						// and it can not be computed yet (otherwise we would have a cycle).
						sp = &c_sp[SS_INDEX(c_ssit)];
						assert(sp->cost < INFINITY);
						assert((sp->state & (SP_CHAIN|SP_VALUE)) == SP_CHAIN);
						S_compute_value(S, x_i, SS_INDEX(c_ssit), sp);
						c_ssit = ss_next(top->c_ss, c_ssit);
						continue;
check_fail:
						POP();
						goto penalty;
					}
				} while(c_ssit);

				// now actually do the check
				if(S_check_ssne(S, top->c->op, top->c->arg, x_i, top->c_ss))
					continue;
penalty:
				top->m_remS -= top->c->penalty;
				dv("%s:%zu -- computed constraint violated for %s~0x%lx [+%f]\n",
						fhk_Dmodel(&S->G, S->G.vars[top->x_i].models[top->m_ei].idx), top->m_inst,
						fhk_Dvar(&S->G, x_i), top->c_ss, top->c->penalty);
				if(UNLIKELY(top->m_remS < 0)){
					top->m_sp->cost = costf(top->m, top->m_betaS - top->m_remS);
					goto next;
				}
			} while(c_ei < m->n_ccheck);

			// this needs to be alive after this loop, but it may have been overwritten by
			// a recursion call
			m_remS = top->m_remS;
		}

		// --------------- computed parameters ------------------

		size_t p_ei = 0;

		// this loop implicitly skips all given parameters, which are edges [n_cparam, n_param)
		while(p_ei < m->n_cparam){ // (m)
			fhk_subset p_ss;
			ssp *p_sp;

			// read edge
			{
				fhk_edge *e = &m->params[p_ei++];
				p_ss = S_map(S, e->map, top->m_inst);

				if(UNLIKELY(!p_ss))
					continue; // empty set: cost 0

				x_i = e->idx;
				p_sp = S_var_ssp(S, x_i);
			}

			top->p_ei = p_ei;
			top->p_ss = p_ss;
			top->p_sp = p_sp;

			float p_ssmax = 0;
			ss_iter p_ssit = ss_first_nonempty(p_ss);

			do { // (p_ssit, p_sp, p_ssmax, m_remS)
				ss_iter next = ss_next(top->p_ss, p_ssit);
				xinst p_ssinst = SS_INDEX(p_ssit);

				if(SP_DONE(p_sp[p_ssinst])){
					// chain solved, cost is true cost
					p_ssmax = max(p_ssmax, p_sp[p_ssinst].cost);
					p_ssit = next;
					if(UNLIKELY(m_remS < p_ssmax)){
						top->m_sp->cost = costf(top->m, top->m_betaS - m_remS + p_ssmax);
						goto next;
					}
				}else{
					// chain not fully solved, recursion time
					top->p_ssmax = p_ssmax;
					top->p_ssit = next;
					beta = m_remS;
					x_inst = p_ssinst;

					PUSH(&&param_return, &&param_fail);
					goto start;

					// return here if solved without cutoff
param_return:
					POP();
					p_ssit = top->p_ssit;
					p_sp = top->p_sp;
					p_ssmax = max(top->p_ssmax, cost);
					m_remS = top->m_remS;

					assert(p_ssmax <= m_remS); // otherwise we should have `goto beta_return`ed
				}
			} while(p_ssit);

			m = top->m;
			m_remS = top->m_remS - p_ssmax;
			top->m_remS = m_remS;
			p_ei = top->p_ei;

			dv("%s:%zu -- solved parameter #%zu: %s~0x%lx [%f], remaining: %f\n",
					fhk_Dmodel(&S->G, S->G.vars[top->x_i].models[top->m_ei].idx), top->m_inst,
					p_ei-1, fhk_Dvar(&S->G, m->params[p_ei-1].idx), top->p_ss, p_ssmax, m_remS);
		}

		// chain is now completely solved for this model, and this model must be the best
		// for the variable
		cost = costf(m, top->m_betaS - m_remS);
		top->m_sp->cost = cost;
		top->m_sp->state = SP_CHAIN;
		dv("%s:%zu -- chain solved [%f]\n",
				fhk_Dmodel(&S->G, S->G.vars[top->x_i].models[top->m_ei].idx), top->m_inst, cost);

		x_i = top->x_i;
		x_inst = top->x_inst;
		m_ei = top->m_ei;
		m_inst = top->m_inst;

choose: // (cost, xi, xinst, m_ei, m_inst)
		{
			ssp *sp = &S->vars[x_i].sp[x_inst];
			sp->cost = cost;
			sp->state = SP_CHAIN_V(m_ei,m_inst);

			dv("=> %s:%zu -- selected candidate %s:%zu [%f] (edge #%d)\n",
					fhk_Dvar(&S->G, x_i), x_inst,
					fhk_Dmodel(&S->G, S->G.vars[x_i].models[m_ei].idx), m_inst,
					cost, m_ei);

			assert(SP_DONE(*sp));

			goto *top->ret_ok;
		}

param_fail:
		POP();
		top->m_sp->cost = costf(top->m, top->m_betaS - top->m_remS + cost);
		// fallthru next

next: // ()
		dv("%s:%zu -- cost too high [%f]\n",
				fhk_Dmodel(&S->G, S->G.vars[top->x_i].models[top->m_ei].idx), top->m_inst, top->m_sp->cost);

		// these were set inside the model loop, so read them back
		x_i = top->x_i;
		x_inst = top->x_inst;
		beta = top->beta;
	}

#undef ISTOP
#undef PUSH
#undef POP
#undef MAX_STK

done:
	return;

fail:
	J_fail(S, FHKE_CHAIN, "no chain with finite cost", FHKEI_V|FHKEI_I, .v=x_i, .i=x_inst);
}
#pragma GCC diagnostic push

// candidate selector:
//     m_ei, m_inst : edge index and instance of the candidate
//     m_beta       : threshold for candidate to be chosen (inf or min cost of next candidate)
#pragma GCC diagnostic push
#if defined(__GNUC__) && !defined(__clang__)
#pragma GCC diagnostic ignored "-Wmaybe-uninitialized"
#endif
static void S_mcand(struct fhk_solver *restrict S, unsigned *m_ei, xinst *m_inst, float *m_cost,
		float *m_beta, struct fhk_var *x, xinst x_inst){

	float f1 = INFINITY;
	float f2 = INFINITY;
	unsigned ei;
	xinst inst;

	for(size_t i=0;i<x->n_mod;i++){
		fhk_subset ss = S_map(S, x->models[i].map, x_inst);
		ssp *sp = S_model_ssp(S, x->models[i].idx);

		for(ss_iter it=ss_first(ss); it; it=ss_next(ss, it)){
			float cost = sp[SS_INDEX(it)].cost;
			ei   = cost < f1 ? i : ei;
			inst = cost < f1 ? SS_INDEX(it) : inst;
			f2   = min(f2, max(f1, cost));
			f1   = min(f1, cost);
		}
	}

	*m_ei = ei;
	*m_inst = inst;
	*m_cost = f1;
	*m_beta = f2;
}
#pragma GCC diagnostic pop

static bool S_check_ssne(struct fhk_solver *restrict S, int op, fhk_arg arg, xidx xi,
		fhk_subset ss){

#ifdef FHK_DEBUG
	assert(ss); // TODO: a better nonempty check

	for(ss_iter it=ss_first(ss); it; it=ss_next(ss, it)){
		if(V_GIVEN(&S->G.vars[xi]))
			assert(S->vars[xi].gs == GS_ALL || bm_isset(S->vars[xi].gs, SS_INDEX(it)));
		else
			assert(S->vars[xi].sp[SS_INDEX(it)].state & SP_VALUE);
	}
#endif

	static const void *cmp_opl[] = {
		[FHKC_GEF64]     = &&cstge_f64,
		[FHKC_LEF64]     = &&cstle_f64,
		[FHKC_GEF32]     = &&cstge_f32,
		[FHKC_LEF32]     = &&cstle_f32,
		[FHKC_U8_MASK64] = &&cstu8_m64
	};

	const void *opl = cmp_opl[op];

	// both gcc and clang generate very confused code for this:
	// - they don't understand that one xmm register can contain either the double or the float.
	//   they don't even just put them in different registers, they put them in different
	//   registers AND keep reloading them from stack (why???????).
	// - they clearly don't understand the loop only loops one label and not the others.
	//
	// if this is slow, it should be rewritter in asm (or at least some inline asm).
	//
	// this could also be optimized with simd, but the sets are generally so small that there
	// is no benefit.
	uint64_t a_r = arg.u64;
	double a_xmmd = arg.f64;  // this goes in xmm0
	float a_xmms = arg.f32;   // this gets reloaded from stack to xmm1 on every iteration ????

	void *vp = S->vars[xi].vp;
	size_t sz = S->G.vars[xi].size;
	ss_iter it = ss_first_nonempty(ss);

	// caller must check that these exist and are valid
	assert(vp);

	do {
		void *v = vp + sz*SS_INDEX(it);
		it = ss_next(ss, it);
		goto *opl;

cstge_f64: if(!(*((double *)v) >= a_xmmd)) return false; continue;
cstle_f64: if(!(*((double *)v) <= a_xmmd)) return false; continue;
cstge_f32: if(!(*((float *)v)  >= a_xmms)) return false; continue;
cstle_f32: if(!(*((float *)v)  <= a_xmms)) return false; continue;
cstu8_m64: if(!((1ULL << *(uint8_t *)v) & a_r)) return false; continue;
	} while(it);

	return true;
}

static void S_get_given_ssne(struct fhk_solver *restrict S, xidx xi, fhk_subset ss){
	assert(V_GIVEN(&S->G.vars[xi]));
	assert(ss);

	uint64_t *gs = S->vars[xi].gs;

	if(LIKELY(gs == GS_ALL))
		return;

	uint64_t udata = S->G.vars[xi].udata.u64;

	xinst inst;

	if(LIKELY(gs)){
		// asymptotically this is not optimal but the test is so fast it doesn't matter
		// (asking for the variable is so much slower)
		while(bm_find0_ssne(gs, &inst, ss)){
			J_yield(S, STATUS(FHKS_COMPUTE_GIVEN | S_A(xi) | S_B(inst), udata));
			if(UNLIKELY(!bm_isset(gs, inst)))
				goto fail;
		}

		return;
	}

	inst = SS_INDEX(ss_first_nonempty(ss));
	J_yield(S, STATUS(FHKS_COMPUTE_GIVEN | S_A(xi) | S_B(inst), udata));
	if(UNLIKELY(!S->vars[xi].gs))
		goto fail;

	// either all given or single value given
	// just make sure we have everything
	// Note: if the first value was not given this will re-request it,
	// but that's not a problem
	S_get_given_ssne(S, xi, ss);
	return;

fail:
	J_fail(S, FHKE_VALUE, "requested instance not given", FHKEI_V|FHKEI_I, .v=xi, .i=inst);
}

static void S_compute_value(struct fhk_solver *restrict S, xidx xi, xinst inst, ssp *sp){
	assert(V_COMPUTED(&S->G.vars[xi]));
	assert(sp == &S->vars[xi].sp[inst]);
	assert((sp->state & (SP_CHAIN|SP_VALUE)) == SP_CHAIN);

	unsigned ei = SP_CHAIN_EI(*sp);
	xinst m_inst = SP_CHAIN_INSTANCE(*sp);
	struct fhk_var *x = &S->G.vars[xi];
	fhk_edge e = x->models[ei];
	ssp *m_sp = &S->models[e.idx].sp[m_inst];
	struct fhk_model *m = &S->G.models[e.idx];

	if(LIKELY(!(m_sp->state & SP_VALUE)))
		S_compute_model(S, e.idx, m_inst, m_sp);

	if(UNLIKELY(!(m->flags & M_NORETBUF))){
		// slow path, see comment in S_compute_model
		void *vp = S_var_vp(S, xi) + x->size*inst;
		fhk_subset ss = S_map(S, m->returns[e.edge_param].map, m_inst);
		// retbuf must be allocated because model returned
		void **retbuf = S->models[e.idx].retbuf + (m_inst * m->n_return);
		void *src = retbuf[e.edge_param] + x->size*ss_indexof(ss, inst);
		memcpy(vp, src, x->size);
	}

	sp->state |= SP_VALUE;

#ifdef FHK_DEBUG
	// do this properly so ubsan won't complain about unaligned access
	union { float f32; double f64; uint64_t u64; } _v = {.u64=0};
	void *_vp = S_var_vp(S, xi) + x->size*inst;
	memcpy(&_v, _vp, x->size);
	dv("%s:%zu -- solved value @ %p [hex: 0x%lx f64: %f f32: %f]\n",
			fhk_Dvar(&S->G, xi), inst, _vp, _v.u64, _v.f64, _v.f32);
#endif
}

static void S_get_computed_ssne(struct fhk_solver *restrict S, xidx xi, fhk_subset ss){
	assert(V_COMPUTED(&S->G.vars[xi]));
	assert(ss);

	// must be chainselected, so sp exists
	ssp *sp = S->vars[xi].sp;

	for(ss_iter it=ss_first_nonempty(ss); it; it=ss_next(ss, it)){
		xinst inst = SS_INDEX(it);
		assert(sp[inst].state & SP_CHAIN);
		if(UNLIKELY(!(sp[inst].state & SP_VALUE)))
			S_compute_value(S, xi, inst, &sp[inst]);
	}
}

static void S_get_value_ssne(struct fhk_solver *restrict S, xidx xi, fhk_subset ss){
	if(LIKELY(V_COMPUTED(&S->G.vars[xi])))
		S_get_computed_ssne(S, xi, ss);
	else
		S_get_given_ssne(S, xi, ss);
}

static void S_compute_model(struct fhk_solver *restrict S, xidx mi, xinst inst, ssp *sp){
	assert(sp == &S->models[mi].sp[inst]);
	assert((sp->state & (SP_CHAIN|SP_VALUE)) == SP_CHAIN);

	sp->state |= SP_VALUE; // well, not yet really, but this lets us forget about it

	struct fhk_model *m = &S->G.models[mi];
	struct fhks_cmodel *cm = alloca(sizeof(*cm) + (m->n_param+m->n_return)*sizeof(*cm->edges));
	cm->instance = inst;
	cm->np = m->n_param;
	cm->nr = m->n_return;
	sc_mask sc_used = 0;

	// collect parameters
	for(size_t i=0;i<m->n_param;i++){
		fhk_edge *e = &m->params[i];
		fhk_subset ss = S_map(S, e->map, inst);

		if(UNLIKELY(!ss)){
			cm->edges[e->edge_param].n = 0;
			continue;
		}

		if(i < m->n_cparam)
			S_get_computed_ssne(S, e->idx, ss);
		else
			S_get_given_ssne(S, e->idx, ss);

		S_collect_ssne(S, &cm->edges[e->edge_param].p, &cm->edges[e->edge_param].n, &sc_used, e->idx, ss);
	}

	// TODO: return edge edge_param is unused so it can be used to store the size.
	//       this avoids looking up S->G.vars[e->idx].size

	if(LIKELY(m->flags & M_NORETBUF)){
		// fast path: we have only 1 return and its return edge map is identity.
		// because we are running this model, it must be optimal for some variable,
		// and because it only has 1 return, it must be optimal for its return.
		// therefore we don't need to alloc the retbuf and instead can write directly
		// to the variable buf
		// NOTE: this function does not set the SP_VALUE flag on the variable, that is the
		//       caller's responsibility
		// NOTE: this could be extended to multiple returns if this is the only model for each
		//       of them
		assert(m->n_return == 1 && MAP_TAG(m->returns[0].map) == FHK_MAP_IDENT);
		cm->edges[m->n_param].n = 1;
		cm->edges[m->n_param].p = S_var_vp(S, m->returns[0].idx) + inst*S->G.vars[m->returns[0].idx].size;
	}else{
		// general case, we must alloc the return buffers
		void **retbuf = S_model_retbuf(S, mi, inst);
		typeof(*cm->edges) *ep = cm->edges + m->n_param;

		for(size_t i=0;i<m->n_return;i++,ep++){
			fhk_edge *e = &m->returns[i];
			fhk_subset ss = S_map(S, e->map, inst);

			if(UNLIKELY(!ss)){
				retbuf[i] = NULL;
				ep->n = 0;
				continue;
			}

			size_t sz = S->G.vars[e->idx].size;
			ep->n = ss_size_nonempty(ss);
			ep->p = retbuf[i] = arena_alloc(S->arena, sz * ep->n, sz);
		}
	}

	// make the request
	J_yield(S, STATUS(FHKS_COMPUTE_MODEL | S_ABC(cm), m->udata.u64));
	S_scratch_release(S, sc_used);
}

static void S_collect_ssne(struct fhk_solver *restrict S, void **p, size_t *num, sc_mask *sc_used,
		xidx xi, fhk_subset ss){

	// everything in the subset MUST have a value, this function doesn't check!

	// XXX: if this mem access hurts then it could be stored in the edge
	size_t sz = S->G.vars[xi].size;
	
	if(LIKELY(SS_NUM(ss) == 1)){
		*p = S->vars[xi].vp + sz*SS_INDEX(ss);
		*num = ss_size_nonempty(ss);
		return;
	}

	// it's a complex subset of multiple ranges, now we have to copy
	size_t n = ss_complex_size(ss);
	void *buf = S_scratch_acquire(S, sc_used, n*sz);
	*p = buf;
	*num = n;

	ss_complex_collect(buf, S->vars[xi].vp, sz, ss);
}

static struct fhk_ei *neweinfo(struct fhk_solver *S){
	return arena_malloc(S->arena, sizeof(struct fhk_ei));
}

static ss_iter ss_first(fhk_subset ss){
	return ss ? ss_first_nonempty(ss) : 0;
}

static ss_iter ss_first_nonempty(fhk_subset ss){
	// don't pass an empty set here

	if(LIKELY(SS_NUM(ss) == 1))
		return ss;

	// nonempty subset, must have SS_NUM(ss) > 1
	assert(SS_NUM(ss) > 1);
	return SS_ITER(1, 0, 0) | *SS_POINTER(ss);
}

static ss_iter ss_next(fhk_subset ss, ss_iter it){
	if(ss <= 0) __builtin_unreachable();
	if(it <= 0) __builtin_unreachable();

	it++;

	// this increment can never overflow the low 16 bits because of the check
	assert(SS_INDEX(it) > 0);

	// not marked as LIKELY because 1-element subsets are so common.
	if(SS_INDEX(it) < SS_END(it))
		return it;

	// note: here it does not necessarily hold that
	//     SS_INDEX(it) == SS_END(it);
	//
	// because the fast encoding for singleton sets is
	//     n        _        end      start
	//     0x0001            0x0000   <index>
	//
	// for the same reason it's not true that
	//     it == SS_ITER(SS_NUM(ss), SS_END(it), SS_END(it)));
	//
	// (TODO: add these assertions for non-fast singleton sets)

	// this comparison works because range index/range count is msb and we always store
	// the NEXT range index.
	if(UNLIKELY(it < ss)){
		int64_t n = SS_NUM(it);
		return SS_ITER(n+1, 0, 0) | SS_POINTER(ss)[n];
	}

	return SS_EMPTY_ITER;
}

static size_t ss_size_nonempty(fhk_subset ss){
	if(LIKELY(SS_NUM(ss) == 1))
		return SS_END(ss) ? RANGE_LEN(ss) : 1;
	return ss_complex_size(ss);
}

static size_t ss_complex_size(fhk_subset ss){
	assert(SS_NUM(ss) > 1);

	size_t sz = 0;
	for(size_t i=0;i<SS_NUM(ss);i++)
		sz += RANGE_LEN(SS_POINTER(ss)[i]);

	return sz;
}

static void ss_complex_collect(void *dest, void *src, size_t sz, fhk_subset ss){
	assert(SS_NUM(ss) > 1);

	uint32_t *rp = SS_POINTER(ss);
	for(size_t i=0;i<SS_NUM(ss);i++){
		uint64_t range = *rp++;
		size_t s = sz * RANGE_LEN(range);
		memcpy(dest, src+sz*SS_INDEX(range), s);
		dest += s;
	}
}

static void ss_collect(void *dest, void *src, size_t sz, fhk_subset ss){
	if(LIKELY(SS_NUM(ss) == 1)){
		memcpy(dest, src, sz*RANGE_LEN(ss));
		return;
	}

	if(SS_NUM(ss) > 1)
		ss_complex_collect(dest, src, sz, ss);
}

static bool ss_contains(fhk_subset ss, xinst inst){
	if(LIKELY(SS_NUM(ss) == 1))
		return SS_END(ss) ? (inst - (uint64_t)SS_INDEX(ss)) < (uint64_t)RANGE_LEN(ss)
			              : inst == SS_INDEX(ss);

	for(size_t i=0;i<SS_NUM(ss);i++){
		uint64_t range = SS_POINTER(ss)[i];
		if((inst - SS_INDEX(range)) >= RANGE_LEN(range))
			return true;
	}

	return false;
}

// inst must be contained in ss or undefined behavior
static size_t ss_indexof(fhk_subset ss, xinst inst){
	assert(ss_contains(ss, inst));

	// this also works for fast singleton
	if(LIKELY(SS_NUM(ss) == 1))
		return inst - SS_INDEX(ss);

	for(size_t i=0;i<SS_NUM(ss);i++){
		uint64_t range = SS_POINTER(ss)[i];
		if((inst - SS_INDEX(range)) >= RANGE_LEN(range))
			return inst - SS_INDEX(range);
	}

	__builtin_unreachable();
}

static ssp *ssp_alloc(struct fhk_solver *S, size_t n, ssp init){
	ssp *sp = arena_malloc(S->arena, n * sizeof(*sp));

	for(size_t i=0;i<n;i++)
		sp[i] = init;

	return sp;
}

static void bm_set(uint64_t *b, xinst inst){
	b[inst >> 6] |= (1ULL << (inst & ~0x3f));
}

static bool bm_isset(uint64_t *b, xinst inst){
	return !!(b[inst >> 6] & (1ULL << (inst & ~0x3f)));
}

// 0 \in [from, to) ?
static bool bm_find0_range(uint64_t *b, xinst *inst, xinst from, xinst to){
	assert(from <= to);

	b = &b[from >> 6];
	xinst next = ((from + 0x40) & ~0x3f);
	xinst end = to < (next-1) ? to : (next-1);
	uint64_t m = *b >> (from & 0x3f);

	for(;;){
		uint64_t mask = (1ULL << (end - from)) - 1;

		if(UNLIKELY((m & mask) != mask)){
			*inst = from + __builtin_ctz(~m);
			return true;
		}

		from = next;
		if(from >= to)
			return false;

		m = *++b;
		next += 64;
		end = to < (next-1) ? to : (next-1);
	}
}

static bool bm_find0_ssne(uint64_t *b, xinst *inst, fhk_subset ss){
	assert(ss);

	if(LIKELY(SS_NUM(ss) == 1)){
		xinst from = SS_INDEX(ss);
		xinst to = SS_END(ss);

		// special case: 1-element sets may be encoded with end=0
		if(!to){
			bool found = !bm_isset(b, from);
			if(found)
				*inst = from;
			return found;
		}

		return bm_find0_range(b, inst, from, to);
	}

	for(size_t i=0;i<SS_NUM(ss);i++){
		uint64_t range = SS_POINTER(ss)[i];
		if(bm_find0_range(b, inst, SS_INDEX(range), SS_END(range)))
			return true;
	}

	return false;
}
