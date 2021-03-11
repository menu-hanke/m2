#include "fhk.h"
#include "def.h"
#include "co.h"

#include "../def.h"
#include "../mem.h"

#include <stdint.h>
#include <stdalign.h>
#include <stdbool.h>
#include <string.h>
#include <assert.h>
#include <math.h>
#include <float.h>

// TODO: benchmark u32 comparisons @ candidate selector
// TODO: benchmark ssiter3 @ candidate selector

#define MAX_COST       FLT_MAX     /* max cost, nothing above will be accepted */
#define MAX_STK        32          /* max working stack size (number of recursive variables) */
#define MAX_CANDSTK    256         /* max candidate stack size */
#define MAX_COSTACK    ((1<<16)+8) /* coroutine stack size (bytes, builtin only), must be 16n+8 */
#define COSTACK_ALIGN  16          /* coroutine stack alignment (bytes, builtin only), must be >= 16 */
#define NUM_SBUF       8           /* number of scratch buffer slots */
#define SBUF_MIN_BITS  16          /* first scratch buffer size */
#define SBUF_ALIGN     8           /* alignment of scratch mem allocations */

#if FHK_DEBUG
#define AINLINE
#else
#define AINLINE __attribute__((always_inline)) inline
#endif

#define NOINLINE __attribute((noinline))

// TODO: this will not work on big endian
#define A_SARG(...)      (((fhk_sarg){__VA_ARGS__}).u64 << 16)

// see fhk.h for subset representation
#define SS_UNDEF         ((fhk_subset)(~0ull))
#define SS_NUMI(ss)      ((ss) & 0xffff)    /* note: num of *remaining* ivals, 0 is valid */
#define SS_ISIVAL(ss)    (!SS_NUMI(ss))
#define SS_ISCOMPLEX(ss) (!!SS_NUMI(ss))
#define SS_CPTR(ss)      ((uint32_t*)((ss) >> 16))
#define SS_CIVAL(ss,n)   (SS_CPTR(ss)[n])
#define SS_IIVAL(ss)     (((ss) >> 16) & 0xffffffff)
#define SS_NONEMPTY(ss)  (!!(ss))

// see below for packed range repr
#define PK_FIRST(pk)      ((pk) & 0xffff)
#define PK_N(pk)          ((-((pk) >> 16)) & 0xffff) /* exclusive */
#define PK_N1(pk)         (1+PK_N(pk))               /* inclusive */

// packed iterator representation. this is for iterating index-by-index.
// an iterator is always valid. use si_* functions for iterating.
//
// +-------------+------------+------------+----------+--------------+------------+
// | 16 (63..48) | 9 (47..39) | 6 (38..33) | 1 (32)   | 16 (31..16)  | 16 (15..0) |
// +-------------+------------+------------+----------+--------------+------------+
// | uref        | uref       | next       | last     | -remaining   | current    |
// | instance    | index      | interval   | interval | instances    | instance   |
// |             |            | hint       | marker   | in interval  |            |
// +-------------+------------+------------+----------+--------------+------------+
// |           complex iterators only                 |
// +--------------------------------------------------+
typedef uint64_t ssiter;

#define SI_UREF_BITS        (G_UMAPBITS+1)
#define SI_HINT_BITS        (15-SI_UREF_BITS)
#define SI_INST             PK_FIRST
#define SI_REM(it)          (((it) >> 16) & 0xffff)
#define SI_UREF_INST(it)    ((it) >> 48)
#define SI_UREF(it)         (((it) >> (32+SI_HINT_BITS)) & ~((1<<SI_UREF_BITS)-1))
#define SI_HINT(it)         (((it) >> 32) & ~((1<<SI_HINT_BITS)-1))
#define SI_SPACE(n)         (((~(uint64_t)(n)) << 16) + 0x00020000ull)
#define SI_RANGE(pk)        ((ssiter)(pk))

static_assert(G_INSTBITS+SI_UREF_BITS+SI_HINT_BITS+1+G_INSTBITS+G_INSTBITS == 8*sizeof(ssiter));

#define SI_CFIRST(inst,uref,p) (((uint64_t)(inst) << 48) | ((uint64_t)(uref) << (32+SI_HINT_BITS)) | (p))
#define SI_CNEXT(it,hint,last,p) (((uint64_t)(it) & ((~0ull) << (32+SI_HINT_BITS))) \
		| (((uint64_t)(hint) & ((1ULL<<SI_HINT_BITS)-1)) << (32+SI_HINT_BITS)) \
		| (((uint64_t)!!(last)) << 32) | (p))

// unfortunately compilers generate confused code with an inline function so you're going
// to have to use this to iterate.
// place this at the end of your for(;;) loop
// notes: (1) this overwrites `it`, (2) this accesses `S`
#define SI_NEXT(it) \
	{ \
		ssiter _it_next = it + 0x00010001; \
		if(LIKELY(it & 0xffff0000)){ it = _it_next; continue; } \
		if(UNLIKELY(it & 0x100000000ull)){ it = si_cnexti(S, it); continue; } \
		break; \
	}

// on linux (sysv) this gets 2 registers so all is fine.
// on windows it gets thrown on the stack but who cares about windows.
// just don't keep this around for too long, gcc is known to generate retarded code for
// small structs. just check the ok immediately after the function returns and store the iterator
// in a register.
// use OSI_* macros to access this, i might change the implementation and pack it to ssiter
typedef struct {
	ssiter si;
	bool valid;
} opt_ssiter;

#define OSI_VALID(osi) ((osi).valid)
#define OSI_SI(osi)    ((osi).si)
#define OSI_V(v,it)    ((opt_ssiter){.valid=(v), .si=(it)})
#define OSI_EMPTYV     ((opt_ssiter){.valid=false})
#define OSI_SIV(it)    ((opt_ssiter){.valid=true, .si=(it)})

// non-packed iterator representation. this is when we want to iterate over ranges rather than
// indices (eg. when memcpying ranges around). note that the complex subset field order is
// the opposite of fhk_subset (XXX: change fhk_subset?)
//
// +-------------+-------------+-------------------+
// |     reg     |    63..16   |       15..0       |
// +-------------+-------------+-------------------+
// | interval    |  iv pointer |    num ivs left   |
// +-------------+-------------+-------------------+
// | instance    |      0      |      instance     |
// +-------------+-------------+-------------------+
// | num         |      0      | iv len (1-based)  |
// +-------------+-------------+-------------------+

typedef uintptr_t ssiter3p;

#define SI3P_COMPLEX(ss) ((ss << 48) | (ss >> 16))
#define SI3P_IINCR       0x3ffff /* decrement nonzero iv num, increment iv pointer by 4 */

#define SI3_NEXTI(it,inst,num) \
	{ \
		if(UNLIKELY(it & 0xffff)) { si3_cnexti(&it, &inst, &num); continue; } \
		break; \
	}

// shared search state representation of vars and models
// (do not change the order of cost and state, it's important)
//
//                         +----------------------------------------+-------------------------------+
//                         |                state                   |             cost              |
//                         +----+----+----+-------+--------+--------+-------+-----------+-----------+
//                         | 63 | 62 | 60 |61..56 | 55..48 | 47..32 | 31(s) | 30..32(e) | 22..0 (m) |
// +-----------------------+----+----+----+-------+--------+--------+-------+-----------+-----------+
// | var/searching         | 0  | 0  | e  |           0             |   1   |     1     |     0     |
// +-----------------------+----+---------+-------------------------+-------+-----------+-----------+
// | var/no chain          | 0  | 0  | e  |           0             |       |                       |
// +-----------------------+----+----+----+-------+--------+--------+       |                       |
// | var/chain+no value    | 1  | 0  | 0  |   0   |        |        |   0   |    cost low bound     |
// +-----------------------+----+----+----+-------+  edge  |  inst  |       |                       |
// | var/chain+value       | 1  | 1  | 0  |   0   |        |        |       |                       |
// +-----------------------+----+----+----+-------+--------+--------+-------+-----------+-----------+
// | shadow/searching      | 0  | 0  | 0  |           0             |   1   |     1     |     0     |
// +-----------------------+----+---------+-------------------------+-------+-----------+-----------+
// | shadow/no chain       | 0  | 0  | 0  |           0             |       |                       |
// +-----------------------+----+----+----+-------------------------+       |                       |
// | shadow/chain          | 1  | 0  | 0  |           0             |       |                       |
// +-----------------------+----+----+----+-------------------------+       |                       |
// | mod/no chain          | 0  | 0  | e  |                         |   0   |    cost low bound     |
// +-----------------------+----+----+----+                         |       |                       |
// | mod/chain+no value    | 1  | 0  |                0             |       |                       |
// +-----------------------+----+----+                              |       |                       |
// | mod/chain+value       | 1  | 1  |                              |       |                       |
// +-----------------------+----+----+------------------------------+-------+-----------------------+
//
// note: the most important invariant the solver maintains is that sp->cost is always a valid
// lower bound, regardless of search state/rounding errors/cycles/whatever, it is ALWAYS
// true that truecost >= sp->cost, for both variables and models.
typedef union {
	struct {
		float cost;
		uint32_t state;
	};
	uint64_t u64;
} ssp;

#define SP_CHAIN              (1ULL << 31)
#define SP_VALUE              (1ULL << 30)
#define SP_EXPANDED           (1ULL << 29)
#define SP_CHAIN_V(e,i)       (SP_CHAIN|((e)<<16)|(i))
#define SP_CHAIN_EI(sp)       (((sp).state >> 16) & 0xff)
#define SP_CHAIN_INSTANCE(sp) ((sp).state & 0xffff)
#define SP_DONEMASK           (SP_CHAIN | 0x7fffffffull)
#define SP_UMAXCOST           ((union { uint32_t u32; float f; }){.f=MAX_COST}).u32
#define SP_DONE(sp)           (((sp).u64 & SP_DONEMASK) >= SP_UMAXCOST)
#define SP_MARK               ((union { uint32_t u32; float f; }){.u32=0x80800000}).f
#define SP_MARKED(sp)         ((sp).cost < 0)

typedef uint64_t bitmap;
#define BM_ALL0 ((bitmap *)(~0ULL))

// shadow state bitmap:
//     
//   +--------------++----------------------------------------+-------------------------------+
//   |      bit     ||                  1                     |                0              |
//   +----------+---++----------------------------------------+-------------------------------+
//   | instance | 0 || guard evaluated and passed, no penalty | guard failed or not evaluated |
//   +----------+---++----------------------------------------+-------------------------------+
//   | instance | 1 ||            guard evaluated             |      guard not evaluated      |
//   +----------+---++----------------------------------------+-------------------------------+
#define SW_PASS          1
#define SW_EVAL          2
#define SW_BMIDX(inst)   ((inst)>>5)
#define SW_BMOFF(inst)   (((inst)<<1)&0x3f)

#define XS_PARAM     0
#define XS_SHADOW    1
#define XS_DONE      2

struct xmodel_bw {
	FHK_MODEL_BW;
};

struct xstate {
	struct xmodel_bw m;    // candidate

	ssp *x_sp;             // target search state

	ssp *m_sp;             // candidate search state

	float x_beta;          // max bound
	float m_beta;          // candidate max bound (only used for detecting infinite loops)

	float m_costS;         // candidate inverse cost
	float m_betaS;         // candidate max inverse cost

	fhk_inst m_inst;       // candidate instance
	uint16_t x_cands;      // candidate stack offset
	uint8_t x_ncand;       // number of candidates
	uint8_t where;         // solver state
	uint8_t m_ei;          // candidate edge

	union {
		struct {
			fhk_shedge *w_edge; // shadow edge
			ssiter w_si; // shadow subset iterator
		};
		struct {
			fhk_edge *p_edge; // parameter edge
			ssiter p_si;   // parameter subset iterator
			float p_ssmax; // parameter subset max cost
		};
	};

#if FHK_DEBUG
	fhk_idx d_xi;
	fhk_idx d_mi;
	fhk_inst d_xinst;
#endif
};

struct xcand {
	uint8_t m_ei;
	fhk_idx m_i;
	ssiter m_si;
	// TODO: we can store the candidate state here and continue from it later,
	// (store m_costS, which location gc/p/cc, and the corresponding edge)
};

struct rootv {
	fhk_idx xi;
	fhk_inst inst, num;
	ssiter3p ip;
	void *buf;
};

// note: scratch buffers are used for temp memory to pass complex subsets outside the solver
// (into model caller). each consecutive scratch buffer doubles in size (except
// the first two, which are equal in size). for example, if SBUF_MIN_BITS=4 then
// the scratch buffers will look like
//
//       S->b_off
//  #0   000xxxx   -->  16 bytes
//  #1   001xxxx   -->  16
//  #2   01xxxxx   -->  32
//  #3   1xxxxxx   -->  64
//
// to reset scratch memory, just set S->b_off = 0

struct fhk_solver {
	ssp *s_mstate[0];          // model search state (must be first)
	fhk_co C;                  // solver coroutine (must have same address as solver)
	struct fhk_graph *G;       // search graph
	fhk_inst *g_shape;         // shape table
	void **s_value;            // value state
	fhk_subset **u_map;        // user mapping cache
	struct xstate x_state[MAX_STK]; // work stack
	struct xcand x_cand[MAX_CANDSTK]; // candidate stack
	uint64_t b_off;            // scratch alloc position
	void *b_mem[NUM_SBUF];     // scratch memory (for passing arguments outside solver)
	arena *arena;              // allocator
	size_t r_nv;               // root count
	struct rootv *r_roots;     // roots
#if FHK_CO_BUILTIN
	fhk_status e_status;       // exit status
#endif
	union {                    // note: these all share the same indexing (all are variable-like)
		ssp *s_vstate[0];      // computed variable search state: see comment on `ssp`
		bitmap *s_vmstate[0];  // given variable missing state: 1 for missing, 0 for have
		bitmap *s_sstate[0];   // shadow state: see comment above
	};
};

static_assert(offsetof(struct fhk_solver, C) == 0);

#define RBUF(mi,m,inst)  (((void **) S->s_value[(mi)]) + (inst)*(m)->p_return)

static void J_shape(struct fhk_solver *S, xgrp group);
static void J_mapcall(struct fhk_solver *S, uint64_t inv, fhk_mapcall *mc);
static void J_vref(struct fhk_solver *S, xidx xi, xinst inst);
static void J_modcall(struct fhk_solver *S, fhk_modcall *mc);

static void JE_maxdepth(struct fhk_solver *S, xidx xi, xinst inst);
static void JE_nyi(struct fhk_solver *S);
static void JE_nvalue(struct fhk_solver *S, xidx xi, xinst inst);
static void JE_nmap(struct fhk_solver *S, xmap idx, xinst inst);
static void JE_nshape(struct fhk_solver *S, xgrp group);
static void JE_nbuf(struct fhk_solver *S);
static void JE_nchain(struct fhk_solver *S, xidx xi, xinst inst);

static void J_exit(struct fhk_solver *S, fhk_status status);

static void S_solve(struct fhk_solver *S);
static void E_exit(struct fhk_solver *S, fhk_status status);

static void S_select_chain_r(struct fhk_solver *S, size_t i);
static void S_get_value_r(struct fhk_solver *S, size_t i);

static void S_vexpandbe(struct fhk_solver *S, xidx xi, xinst inst);
static void S_mexpandbe(struct fhk_solver *S, xidx mi, xinst inst);
static void S_vexpandsp(struct fhk_solver *S, xidx xi);
static void S_vexpandss(struct fhk_solver *S, xidx wi);
static void S_vexpandvp(struct fhk_solver *S, xidx xi);
static void S_mexpandsp(struct fhk_solver *S, xidx mi);
static void S_mexpandvp(struct fhk_solver *S, xidx mi);
static void S_pexpand(struct fhk_solver *S, xmap map, xinst inst);
static void S_getumap(struct fhk_solver *S, xmap map, xinst inst);
static fhk_inst S_shape(struct fhk_solver *S, xgrp group);
static void S_getshape(struct fhk_solver *S, xgrp group);

static size_t S_map_size(struct fhk_solver *S, xmap map, xinst inst);

static void S_select_chain(struct fhk_solver *S, xidx xi, xinst inst);

static uint64_t S_check1(struct fhk_solver *S, struct fhk_shadow *w, xinst inst);
static void S_checkspace(struct fhk_solver *S, struct fhk_shadow *w, bitmap *state);

static void S_get_given(struct fhk_solver *S, xidx xi, xmap map, xinst inst);
static void S_get_missing_si3ne(struct fhk_solver *S, xidx xi, ssiter3p sip, xinst sinst,
		xinst sinum);

static void S_compute_value(struct fhk_solver *S, xidx xi, xinst inst);
static void S_get_computed_si(struct fhk_solver *S, ssiter it, xidx xi);

static void S_collect_mape(struct fhk_solver *S, fhk_mcedge *e, xidx xi, xmap map,
		xinst m_inst);
static void *S_sbuf_alloc(struct fhk_solver *S, size_t size);

static void *sbuf_alloc_init(struct fhk_solver *S, size_t size);

static void p_directref(struct fhk_solver *S, fhk_mcedge *e, xidx xi, xmap map, xinst m_inst);
static opt_ssiter p_ssiter(struct fhk_solver *S, xmap map, xinst inst);
static void p_ssiter3(struct fhk_solver *S, xmap map, xinst inst, ssiter3p *sip,
		xinst *sinst, xinst *sinum);
static xinst p_packidxofe(struct fhk_solver *S, xmap map, xinst m_inst, xinst inst);

static void si3_ss(fhk_subset ss, ssiter3p *sip, xinst *sinst, xinst *sinum);
static void si3_complex(fhk_subset ss, ssiter3p *sip, xinst *sinst, xinst *sinum);
static ssiter si_cnexti(struct fhk_solver *S, ssiter it);
static void si3_cnexti(ssiter3p *p, xinst *inst, xinst *num);
static void si3_collect_ne(void *dest, void *src, size_t sz, ssiter3p ip, xinst inst, xinst num);

static xinst ss_cpackidxof(fhk_subset ss, xinst inst);
static size_t ss_csize(fhk_subset ss);

static bitmap *bm_alloc(struct fhk_solver *S, xinst n, bitmap init);
static void bm_clear(bitmap *b, xinst inst);
static bool bm_isset(bitmap *b, xinst inst);
static bool bm_find1_iv(bitmap *bm, xinst *inst, xinst end);

static ssp *ssp_alloc(struct fhk_solver *S, size_t n, ssp init);
static void r_copyroots(struct fhk_solver *S, size_t nv, struct fhk_req *req);

static const char *dstrvalue(struct fhk_solver *S, xidx xi, xinst inst);

fhk_solver *fhk_create_solver(struct fhk_graph *G, arena *arena, size_t nv, struct fhk_req *req){
	// not a hard requirement, just makes the alloc code simpler.
	// if this is changed then aligning needs to be done more carefully.
	static_assert(alignof(struct fhk_solver) == alignof(void *));

	// lazy use of memset
	static_assert(FHK_NINST == 0xffff);

#if FHK_CO_BUILTIN
	// TODO: this should probably not allocate it on the arena, instead mmap a stack
	// with a guard page. now stack overflows can corrupt the arena.
	void *stack = arena_alloc(arena, MAX_COSTACK, COSTACK_ALIGN);
#endif
	
	struct fhk_solver *S = arena_alloc(arena, sizeof(void *)*(G->nx+G->nm)+sizeof(*S), alignof(*S));
	S = (void *)S + G->nm * sizeof(*S->s_mstate);
	S->g_shape  = arena_alloc(arena, G->ng * sizeof(*S->g_shape), alignof(*S->g_shape));
	S->s_value  = G->nm + (void **) arena_alloc(arena, (G->nv+G->nm) * sizeof(*S->s_value), alignof(*S->s_value));
	S->u_map    = arena_alloc(arena, 2*G->nu * sizeof(*S->u_map), alignof(*S->u_map));
	S->r_roots  = arena_alloc(arena, nv * sizeof(*S->r_roots), alignof(*S->r_roots));
	S->b_mem[0] = arena_alloc(arena, 1 << SBUF_MIN_BITS, SBUF_ALIGN);

	S->G = G;
	S->arena = arena;

#if FHK_CO_BUILTIN
	fhk_co_init(&S->C, stack, MAX_COSTACK, &S_solve);
#else
	fhk_co_init(&S->C, &S_solve);
#endif

	memset(S->s_mstate - G->nm, 0, G->nm * sizeof(*S->s_mstate));
	memset(S->s_vstate, 0, G->nx * sizeof(*S->s_vstate));
	memset(S->g_shape, 0xff, G->ng * sizeof(*S->g_shape));
	memset(S->s_value - G->nm, 0, (G->nv+G->nm) * sizeof(*S->s_value));
	memset(S->u_map, 0, 2*G->nu * sizeof(*S->u_map));
	memset(S->b_mem+1, 0, (NUM_SBUF-1) * sizeof(*S->b_mem));

	r_copyroots(S, nv, req);

	S->b_off = 0;
	S->x_state->where = XS_DONE;
	S->x_state->x_cands = 0;
	S->x_state->x_ncand = 0;

	return S;
}

static void fhkS_setshape(struct fhk_solver *S, xgrp group, xinst shape){
	if(UNLIKELY(shape > G_MAXINST)){
		E_exit(S, FHK_ERROR | A_SARG(.s_ei = FHKE_INVAL | E_META(1, G, group) | E_META(2, J, shape)));
		return;
	}

	if(UNLIKELY(S->g_shape[group] != FHK_NINST)){
		E_exit(S, FHK_ERROR | A_SARG(.s_ei = FHKE_OVERWRITE | E_META(1, G, group)));
		return;
	}

	dv("shape[%zu] -> %zu\n", group, shape);
	S->g_shape[group] = shape;
}

void fhkS_shape(struct fhk_solver *S, fhk_grp group, fhk_inst shape){
	if(UNLIKELY(group >= S->G->ng)){
		E_exit(S, FHK_ERROR | A_SARG(.s_ei = FHKE_INVAL | E_META(1, G, group)));
		return;
	}

	fhkS_setshape(S, group, shape);
}

void fhkS_shape_table(struct fhk_solver *S, fhk_inst *shape){
	// if multiple of these fail, the last one is stored, that's ok
	for(xinst i=0;i<S->G->ng;i++)
		fhkS_setshape(S, i, shape[i]);
}

void fhkS_give(struct fhk_solver *S, fhk_idx xi, fhk_inst inst, void *vp){
	if(xi > S->G->nv || UNLIKELY(!V_GIVEN(&S->G->vars[xi]))){
		E_exit(S, FHK_ERROR | A_SARG(.s_ei = FHKE_INVAL | E_META(1, I, xi)));
		return;
	}

	struct fhk_var *x = &S->G->vars[xi];
	xinst shape = S->g_shape[x->group];

	// TODO: you don't have to return an error here: there's a workaround but it's a bit complex:
	//       store xi,inst,vp somewhere and jump on the solver stack to a function that will
	//       yield FHKS_SHAPE, then copy the variable. (this is similar to how E_exit works)
	//       (you don't have to use the solver stack, you can allocate a new one via the arena,
	//       scratch buffers, malloc, etc...)
	if(UNLIKELY(shape == FHK_NINST)){
		E_exit(S, FHK_ERROR | A_SARG(.s_ei = FHKE_NYI | E_META(1, G, x->group) | E_META(2, J, inst)));
		return;
	}

	if(UNLIKELY(inst >= shape)){
		E_exit(S, FHK_ERROR | A_SARG(.s_ei = FHKE_INVAL | E_META(1, G, x->group) | E_META(2, J, inst)));
		return;
	}

	if(UNLIKELY(S->s_value[xi] == BM_ALL0)){
		E_exit(S, FHK_ERROR | A_SARG(.s_ei = FHKE_INVAL | E_META(1, I, xi) | E_META(2, J, inst)));
		return;
	}

	if(UNLIKELY(!S->s_vmstate[xi]))
		S->s_vmstate[xi] = bm_alloc(S, shape, ~0ULL);

	if(UNLIKELY(!S->s_value[xi]))
		S->s_value[xi] = arena_alloc(S->arena, shape*x->size, x->size);

	bm_clear(S->s_vmstate[xi], inst);
	memcpy(S->s_value[xi] + inst*x->size, vp, x->size);

	dv("%s:%u -- given value @ %p -> %p [%s]\n",
			fhk_dsym(S->G, xi), inst,
			vp, S->s_value[xi] + inst*x->size,
			dstrvalue(S, xi, inst));
}

void fhkS_give_all(struct fhk_solver *S, fhk_idx xi, void *vp){
	if(UNLIKELY(!V_GIVEN(&S->G->vars[xi]))){
		E_exit(S, FHK_ERROR | A_SARG(.s_ei = FHKE_INVAL | E_META(1, I, xi)));
		return;
	}

	if(UNLIKELY(S->s_vmstate[xi])){
		E_exit(S, FHK_ERROR | A_SARG(.s_ei = FHKE_OVERWRITE | E_META(1, I, xi)));
		return;
	}

	assert(!S->s_value[xi]);

	S->s_vmstate[xi] = BM_ALL0;
	S->s_value[xi] = vp;

	dv("%s -- given buffer @ %p\n", fhk_dsym(S->G, xi), vp);
}

// inspection functions - use these for debugging only, they expose solver internals and are slow

float fhkI_cost(struct fhk_solver *S, fhk_idx idx, fhk_inst inst){
	ssp *sp;

	if(ISVI(idx)){
		if(V_GIVEN(&S->G->vars[idx]))
			return 0;

		sp = S->s_vstate[idx];
	}else{
		sp = S->s_mstate[idx];
	}

	return sp ? sp[inst].cost : 0;
}

fhk_inst fhkI_shape(struct fhk_solver *S, fhk_grp group){
	return S->g_shape[group];
}

fhk_eref fhkI_chain(struct fhk_solver *S, fhk_idx xi, fhk_inst inst){
	ssp *sp = S->s_vstate[xi];
	if(V_GIVEN(&S->G->vars[xi]) || !sp || !(sp[inst].state & SP_CHAIN))
		return (fhk_eref){.idx=FHK_NIDX, .inst=FHK_NINST};

	return (fhk_eref){
		.idx = S->G->vars[xi].models[SP_CHAIN_EI(sp[inst])].idx,
		.inst = SP_CHAIN_INSTANCE(sp[inst])
	};
}

void *fhkI_value(struct fhk_solver *S, fhk_idx xi, fhk_inst inst){
	struct fhk_var *x = &S->G->vars[xi];

	if(LIKELY(V_COMPUTED(x))){
		ssp *sp = S->s_vstate[xi];
		if(!sp || !(sp[inst].state & SP_VALUE))
			return NULL;
	}else{
		bitmap *missing = S->s_vmstate[xi];
		if(!missing || (missing != BM_ALL0 && bm_isset(missing, inst)))
			return NULL;
	}

	return S->s_value[xi] + x->size*inst;
}

struct fhk_graph *fhkI_G(struct fhk_solver *S){
	return S->G;
}

AINLINE static void J_shape(struct fhk_solver *S, xgrp group){
	dv("-> SHAPE   %zu\n", group);
	fhkJ_yield(&S->C, FHKS_SHAPE | A_SARG(.s_group=group));
}

AINLINE static void J_mapcall(struct fhk_solver *S, uint64_t inv, fhk_mapcall *mc){
	dv("-> MAPCALL %c%d:%u -> %p\n", inv ? '<' : '>', mc->mref.idx, mc->mref.inst, mc->ss);
	fhkJ_yield(&S->C, FHKS_MAPCALL | inv | A_SARG(.s_mapcall=mc));
}

AINLINE static void J_vref(struct fhk_solver *S, xidx xi, xinst inst){
	dv("-> VREF    %s:%zu\n", fhk_dsym(S->G, xi), inst);
	fhkJ_yield(&S->C, FHKS_VREF | A_SARG(.s_vref={.idx=xi, .inst=inst}));
}

AINLINE static void J_modcall(struct fhk_solver *S, fhk_modcall *mc){
	dv("-> MODCALL %s:%u (%u->%u)\n", fhk_dsym(S->G, mc->mref.idx), mc->mref.inst, mc->np, mc->nr);
	fhkJ_yield(&S->C, FHKS_MODCALL | A_SARG(.s_modcall=mc));
}

__attribute__((cold, noreturn))
static void JE_maxdepth(struct fhk_solver *S, xidx xi, xinst inst){
	J_exit(S, FHK_ERROR | A_SARG(.s_ei = FHKE_DEPTH | E_META(1, I, xi) | E_META(2, J, inst)));
}

__attribute__((cold, noreturn))
static void JE_nyi(struct fhk_solver *S){
	J_exit(S, FHK_ERROR | A_SARG(.s_ei = FHKE_NYI));
}

__attribute__((cold, noreturn))
static void JE_nvalue(struct fhk_solver *S, xidx xi, xinst inst){
	J_exit(S, FHK_ERROR | A_SARG(.s_ei = FHKE_NVALUE | E_META(1, I, xi) | E_META(2, J, inst)));
}

__attribute__((cold, noreturn))
static void JE_nmap(struct fhk_solver *S, xmap idx, xinst inst){
	J_exit(S, FHK_ERROR | A_SARG(.s_ei = FHKE_NVALUE | E_META(1, P, idx) | E_META(2, J, inst)));
}

__attribute__((cold, noreturn))
static void JE_nshape(struct fhk_solver *S, xgrp group){
	J_exit(S, FHK_ERROR | A_SARG(.s_ei = FHKE_NVALUE | E_META(1, G, group)));
}

__attribute__((cold, noreturn))
static void JE_nbuf(struct fhk_solver *S){
	J_exit(S, FHK_ERROR | A_SARG(.s_ei = FHKE_MEM));
}

__attribute__((cold, noreturn))
static void JE_nchain(struct fhk_solver *S, xidx xi, xinst inst){
	J_exit(S, FHK_ERROR | A_SARG(.s_ei = FHKE_CHAIN | E_META(1, I, xi) | E_META(2, J, inst)));
}

__attribute__((noreturn))
static void J_exit(struct fhk_solver *S, fhk_status status){
#if FHK_CO_BUILTIN
	for(;;)
		fhkJ_yield(&S->C, status);
#else
	fhk_co_done(&S->C);
	fhkJ_yield(&S->C, status);
#endif
}

__attribute__((cold))
static void SE_exit(struct fhk_solver *S){
	J_exit(S, S->e_status);
}

__attribute__((cold))
static void E_exit(struct fhk_solver *S, fhk_status status){
#if FHK_CO_BUILTIN
	S->e_status = status;
	fhk_co_jmp(&S->C, &SE_exit);
#else
	fhk_co_done(&S->C);
#endif
}

static void S_solve(struct fhk_solver *S){
	// optimization: if we know the shapes and the requested subset is space, then
	// collect directly to the given buffer, instead of copying.
	for(size_t i=0;i<S->r_nv;i++){
		struct rootv *r = &S->r_roots[i];
		struct fhk_var *x = &S->G->vars[r->xi];

		if(UNLIKELY(V_GIVEN(x)))
			continue;

		// num can't be FHK_NINST so this check is ok even if we don't have the shape.
		// we *could* request the shape at this point if we don't have it, but currently we don't.
		if(S->g_shape[x->group] == r->num && !S->s_value[r->xi])
			S->s_value[r->xi] = r->buf;
	}

	// select chains for all first, to keep the solver state in cache, instead of jumping
	// to a model caller after each root
	for(size_t i=0;i<S->r_nv;i++)
		S_select_chain_r(S, i);

	// this actually invokes the model calls (except for those that were invoked by computed
	// constraints in the first step)
	for(size_t i=0;i<S->r_nv;i++)
		S_get_value_r(S, i);

	// and finally collect
	for(size_t i=0;i<S->r_nv;i++){
		struct rootv *r = &S->r_roots[i];
		void *vp = S->s_value[r->xi];

		assert(vp);

		// fast path: request was space, we used direct buffer, nothing to do
		if(LIKELY(vp == r->buf))
			continue;

		si3_collect_ne(r->buf, vp, r->xi, r->ip, r->inst, r->num);
	}

	J_exit(S, FHK_OK);
}

AINLINE static void S_select_chain_r(struct fhk_solver *S, size_t i){
	struct rootv *r = &S->r_roots[i];
	xidx xi = r->xi;
	ssiter3p ip = r->ip;
	xinst inst = r->inst;
	xinst num = r->num;

	assert(num > 0);

	if(UNLIKELY(V_GIVEN(&S->G->vars[xi])))
		return;

	S_vexpandsp(S, xi);
	ssp *sp = S->s_vstate[xi];

	for(;;){
		do {
			if(!SP_DONE(sp[inst]))
				S_select_chain(S, xi, inst);
			inst++;
		} while(--num > 0);
		SI3_NEXTI(ip, inst, num);
	}
}

AINLINE static void S_get_value_r(struct fhk_solver *S, size_t i){
	struct rootv *r = &S->r_roots[i];
	struct fhk_var *x = &S->G->vars[r->xi];
	xidx xi = r->xi;

	if(LIKELY(V_COMPUTED(x))){
		ssp *sp = S->s_vstate[xi];
		ssiter3p ip = r->ip;
		xinst inst = r->inst;
		xinst num = r->num;

		for(;;){
			do {
				if(LIKELY(!(sp[inst].state & SP_VALUE)))
					S_compute_value(S, xi, inst);
				inst++;
			} while(--num > 0);
			SI3_NEXTI(ip, inst, num);
		}
	}else{
		bitmap *missing = S->s_vmstate[xi];
		if(LIKELY(missing == BM_ALL0))
			return;

		S_get_missing_si3ne(S, xi, r->ip, r->inst, r->num);
	}
}

// expand backward edges of computed variable
static void S_vexpandbe(struct fhk_solver *S, xidx xi, xinst inst){
	struct fhk_var *x = &S->G->vars[xi];
	assert(V_COMPUTED(x));

	size_t i = 0;
	do {
		S_mexpandsp(S, x->models[i].idx);
		S_pexpand(S, x->models[i].map, inst);
	} while(++i < x->n_mod);
}

// expand backward edges of model
static void S_mexpandbe(struct fhk_solver *S, xidx mi, xinst inst){
	struct fhk_model *m = &S->G->models[mi];

	for(int64_t i=m->p_shadow;i;i++){
		S_vexpandss(S, m->shadows[i].idx);
		S_pexpand(S, m->shadows[i].map, inst);
	}

	for(int64_t i=0;i<m->p_cparam;i++){
		S_vexpandsp(S, m->params[i].idx);
		S_pexpand(S, m->params[i].map, inst);
	}
}

AINLINE static void S_vexpandsp(struct fhk_solver *S, xidx xi){
	assert(V_COMPUTED(&S->G->vars[xi]));

	if(LIKELY(S->s_vstate[xi]))
		return;

	S->s_vstate[xi] = ssp_alloc(S, S_shape(S, S->G->vars[xi].group), (ssp){.state=0,.cost=0});
}

AINLINE static void S_vexpandss(struct fhk_solver *S, xidx wi){
	if(LIKELY(S->s_sstate[wi]))
		return;

	S->s_sstate[wi] = bm_alloc(S, S_shape(S, S->G->shadows[wi].group), 0);
}

AINLINE static void S_vexpandvp(struct fhk_solver *S, xidx xi){
	assert(V_COMPUTED(&S->G->vars[xi]));

	if(LIKELY(S->s_value[xi]))
		return;

	struct fhk_var *x = &S->G->vars[xi];
	size_t size = x->size;
	size_t n = S_shape(S, x->group);
	S->s_value[xi] = arena_alloc(S->arena, n*size, size);
}

AINLINE static void S_mexpandsp(struct fhk_solver *S, xidx mi){
	if(LIKELY(S->s_mstate[mi]))
		return;

	struct fhk_model *m = &S->G->models[mi];
	S->s_mstate[mi] = ssp_alloc(S, S_shape(S, m->group), (ssp){.cost=m->cmin, .state=0});
}

AINLINE static void S_mexpandvp(struct fhk_solver *S, xidx mi){
	if(LIKELY(S->s_value[mi]))
		return;

	struct fhk_model *m = &S->G->models[mi];
	assert(!(m->flags & M_NORETBUF));

	S->s_value[mi] = arena_alloc(S->arena, S_shape(S, m->group) * m->p_return * sizeof(void *),
			alignof(void *));
}

// expand mapping
static void S_pexpand(struct fhk_solver *S, xmap map, xinst inst){
	if(UNLIKELY(P_ISSPACE(map) && (S->g_shape[map] == FHK_NINST)))
		S_getshape(S, map);
	else if(UNLIKELY(P_ISUSER(map)))
		S_getumap(S, map, inst);
}

// expand user mapping
static void S_getumap(struct fhk_solver *S, xmap map, xinst inst){
	fhk_subset *cache = S->u_map[map & P_UREF];

	if(UNLIKELY(!cache)){
		size_t shape = S_shape(S, P_UGROUP(map));
		cache = S->u_map[map & P_UREF] = arena_alloc(S->arena, shape * sizeof(*cache),
				alignof(*cache));
		for(xinst i=0;i<shape;i++)
			cache[i] = SS_UNDEF;
	}else if(LIKELY(cache[inst] != SS_UNDEF))
		return;

	fhk_mapcall mp = {
		.mref = {
			.idx = P_UIDX(map),
			.inst = inst
		},
		.ss = &cache[inst]
	};

	J_mapcall(S, map & P_UINV, &mp);

	if(UNLIKELY(cache[inst] == SS_UNDEF))
		JE_nmap(S, P_UIDX(map), inst);

	dv("umap %c%zu:%zu -> 0x%lx\n", (map & P_UINV) ? '<' : '>', P_UIDX(map), inst, cache[inst]);
}

AINLINE static fhk_inst S_shape(struct fhk_solver *S, xgrp group){
	assert(group < S->G->ng);

	if(UNLIKELY(S->g_shape[group] == FHK_NINST))
		S_getshape(S, group);

	return S->g_shape[group];
}

static void S_getshape(struct fhk_solver *S, xgrp group){
	assert(group < S->G->ng);
	assert(S->g_shape[group] == FHK_NINST);

	J_shape(S, group);

	if(UNLIKELY(S->g_shape[group] == FHK_NINST))
		JE_nshape(S, group);
}

AINLINE static size_t S_map_size(struct fhk_solver *S, xmap map, xinst inst){
	if(LIKELY(P_ISIDENT(map)))
		return 1;

	if(LIKELY(P_ISSPACE(map)))
		return S_shape(S, map);

	assert(P_ISUSER(map));
	S_getumap(S, map, inst);
	fhk_subset ss = S->u_map[map & P_UREF][inst];

	if(LIKELY(SS_ISIVAL(ss)))
		return PK_N1(SS_IIVAL(ss));

	return ss_csize(ss);
}

// main solver.
//
//                       +-----------------------------[already have chain]-------------------+
//                       |                                                                    |
//                       |    +-------------------[cost > beta]---------+                     |
//                       |    v                                         |                     |
//                       | x_bound <-[cost>beta]-+                      |                     |
//                       |    |                  |                      |                     |
// +--[no candidate]----+|    |                  |                      |                     |
// |                    ||    |                  |                      |                     |
// |                    ||    v                  |                      |                     v
// |  x_solve ------> candidate ------> (shadow solver) ------> (parameter solver) -----> x_chosen
// |    ^ ^                                  |   ^                   |      ^               | | |
// |    | |                                  |   |                   |      |               | | |
// |    | +--------[computed shadow]---------+   |                   |      |               | | |
// |    +----------[computed parameter]----------|-------------------+      |               | | |
// |                                             |                          |               | | |
// |                                      [resume shadow]           [resume parameter]      | | |
// |                                         ^      ^                    ^      ^           | | |
// |                                         |      |                    |      |           | | |
// +-----------------------> x_failed -------+      |                    |      +-----------+ | |
//                              |                   +-----------------------------------------+ |
//                              |                                        |                      |
//                              +----------------------------------------+    return, done. <---+
// 
// state transition variables. (any competent compiler with an ssa will optimize this).
//
//                 +-----+--------+--------+--------+---------+---------+
//                 | X_i | X_inst | X_beta | X_cost | M_costS | M_betaS |
// +---------------+-----+--------+--------+--------+---------+---------+
// | x_solve       |  X  |   X    |   X    |        |         |         |
// +---------------+-----+--------+--------+--------+---------+---------+
// | x_chosen      |     |        |        |   X    |         |         |
// +---------------+-----+--------+--------+--------+---------+---------+
// | x_failed      |     |        |        |   X    |         |         |
// +---------------+-----+--------+--------+--------+---------+---------+
// | x_bound       |     |        |        |        |    x    |         |
// +---------------+-----+--------+--------+--------+---------+---------+
// | candidate     |     |        |        |        |         |         |
// +---------------+-----+--------+--------+--------+---------+---------+
// | param_*       |     |        |        |        |   \/    |   \/    |
// | shadow_*      |     |        |        |        |   /\    |   /\    |
// +---------------+-----+--------+--------+--------+---------+---------+
static void S_select_chain(struct fhk_solver *S, xidx _x_i, xinst _x_inst){
	register struct xstate *X = S->x_state;

	xidx X_i = _x_i;
	xinst X_inst = _x_inst;
	float X_beta = MAX_COST;
	float X_cost = 0;
	float M_costS = 0;
	float M_betaS = 0;

x_solve:  // -> X_i, X_inst, X_beta
	{
		dv("%s:%zu -- enter solver (depth: %ld  beta: %g)\n",
				fhk_dsym(S->G, X_i), X_inst, X-S->x_state, X_beta);

		ssp *sp = &S->s_vstate[X_i][X_inst];

		assert(!SP_DONE(*sp));
		assert(X_beta >= sp->cost);

		X->m_costS = M_costS;
		X->m_betaS = M_betaS;

		X++;

		X->x_sp = sp;
		X->x_beta = X_beta;
#if FHK_DEBUG
		X->d_xi = X_i;
		X->d_xinst = X_inst;
#endif

		if(UNLIKELY(X-S->x_state >= MAX_STK))
			JE_maxdepth(S, X_i, X_inst);

		if(UNLIKELY(SP_MARKED(*sp)))
			JE_nyi(S); // cycle

		if(!(sp->state & SP_EXPANDED)){
			assert(!sp->state);
			sp->state = SP_EXPANDED;
			S_vexpandbe(S, X_i, X_inst);
		}

		sp->cost = SP_MARK;

		struct fhk_var *x = &S->G->vars[X_i];
		assert(V_COMPUTED(x));

		size_t cstart = (X-1)->x_cands + (X-1)->x_ncand;
		X->x_cands = cstart;

		if(UNLIKELY(cstart + x->n_mod >= MAX_CANDSTK))
			JE_maxdepth(S, X_i, X_inst);

		struct xcand *cand = &S->x_cand[cstart];
		size_t nc = 0;
		size_t ei = 0;

		do {
			opt_ssiter osi = p_ssiter(S, x->models[ei].map, X_inst);

			if(UNLIKELY(!OSI_VALID(osi)))
				continue;

			cand->m_ei = ei;
			cand->m_i = x->models[ei].idx;
			cand->m_si = OSI_SI(osi);
			cand++;
			nc++;
		} while(++ei < x->n_mod);

		X->x_ncand = nc;

		if(LIKELY(nc > 0))
			goto candidate;

		X_cost = INFINITY;
		goto x_failed;
	}

x_chosen: // -> X_cost
	{
		dv("%s:%u [%s:%u] -- selected candidate [%g/%g] (edge #%u)\n",
				fhk_dsym(S->G, X->d_xi), X->d_xinst,
				fhk_dsym(S->G, X->d_mi), X->m_inst,
				X_cost, X->x_beta,
				SP_CHAIN_EI(*X->x_sp));

		assert(X->x_sp->state & SP_CHAIN);
		X->x_sp->cost = X_cost;
		X--;

		M_costS = X->m_costS;
		M_betaS = X->m_betaS;
		uint8_t where = X->where;

		if(LIKELY(where == XS_PARAM))
			goto param_solved;

		if(LIKELY(where == XS_SHADOW))
			goto shadow_solved;

		assert(where == XS_DONE);
		return;
	}

x_failed: // -> X_cost
	{
		dv("%s:%u -- no candidate with cost <= %g, cost is at least %g\n",
				fhk_dsym(S->G, X->d_xi), X->d_xinst, X->x_beta, X_cost);

		// this bound was not known before because we came here
		assert(X->x_sp->cost < X_cost);
		X->x_sp->cost = X_cost;

		X--;
		uint8_t where = X->where;

		if(LIKELY(where == XS_PARAM)){
			X->x_sp->cost = costf((struct fhk_model *)&X->m, X->m_costS + X_cost);
			X->m_sp->cost = X->x_sp->cost;
			goto candidate;
		}

		M_costS = X->m_costS;
		M_betaS = X->m_betaS;

		if(LIKELY(where == XS_SHADOW))
			goto shadow_failed;

		assert(where == XS_DONE);
		JE_nchain(S, _x_i, _x_inst);
	}

x_bound:
	{
		dv("%s:%u [%s:%u] -- candidate s-cost over beta: %g > %g\n",
				fhk_dsym(S->G, X->d_xi), X->d_xinst,
				fhk_dsym(S->G, X->d_mi), X->m_inst,
				M_costS, M_betaS);

		X->m_sp->cost = costf((struct fhk_model *)&X->m, M_costS);

		if(UNLIKELY(X->m_sp->cost <= X->m_beta))
			JE_nyi(S); // fp instability

		goto candidate;
	}
	
candidate:

	// ---------------- candidate selection ----------------
	{
		float m_cost = INFINITY;
		float m_beta = X->x_beta;
		size_t maxcand = X->x_cands + X->x_ncand;
		size_t x_cind = X->x_cands;
		struct xcand *m_cand = NULL;
		xinst m_inst = 0;

		do {
			struct xcand *cand = &S->x_cand[x_cind];
			ssiter it = cand->m_si;
			ssp *sp = S->s_mstate[cand->m_i];

			assert(S->g_shape[S->G->models[cand->m_i].group] != FHK_NINST);

			for(;;){
				assert(SI_INST(it) < S->g_shape[S->G->models[cand->m_i].group]);

				float cost = sp[SI_INST(it)].cost;
				m_cand = cost < m_cost ? cand : m_cand;
				m_inst = cost < m_cost ? SI_INST(it) : m_inst;
				m_beta = min(m_beta, max(m_cost, cost));
				m_cost = min(m_cost, cost);

				SI_NEXT(it);
			}
		} while(++x_cind < maxcand);

		// no candidate
		if(UNLIKELY(m_cost > X->x_beta)){
			X_cost = m_cost;
			goto x_failed;
		}

		xidx mi = m_cand->m_i;

		dv("%s:%u [%s:%zu] -- candidate low bound: %g (%g)  beta: %g (%g)\n",
				fhk_dsym(S->G, X->d_xi), X->d_xinst,
				fhk_dsym(S->G, mi), m_inst,
				m_cost, costf_invS(&S->G->models[mi], m_cost),
				m_beta, costf_invS(&S->G->models[mi], m_beta));

		ssp *sp = &S->s_mstate[mi][m_inst];
		struct fhk_model *m = &S->G->models[mi];

#if FHK_DEBUG
		X->d_mi = mi;
#endif
		X->m_ei = m_cand->m_ei;
		X->m_inst = m_inst;
		X->m_sp = sp;
		X->m = *(struct xmodel_bw *) m;
		M_betaS = costf_invS(m, m_beta);
		M_costS = 0;

		// this model already has a chain?
		// this means that the exact cost is known and below selection threshold, so there
		// is nothing to do.
		// this could happen because this is a multireturn model and the other variable
		// was already solved.
		if(UNLIKELY(sp->state & SP_CHAIN)){
			X_cost = m_cost;
			X->x_sp->state = SP_CHAIN_V(m_cand->m_ei, m_inst);
			goto x_chosen;
		}

		if(UNLIKELY(!(sp->state & SP_EXPANDED))){
			assert(!sp->state);
			sp->state = SP_EXPANDED;
			S_mexpandbe(S, mi, m_inst);
		}
	}

	// ---------------- shadow parameters ----------------
	if(X->m.p_shadow != 0){
		fhk_shedge *s_edge = &X->m.shadows[X->m.p_shadow];
		X->where = XS_SHADOW;

		do {
			ssiter si;
			bitmap *ss;
			struct fhk_shadow *w;
			xinst inst;

			{
				ss = S->s_sstate[s_edge->idx];
				opt_ssiter osi = p_ssiter(S, s_edge->map, X->m_inst);
				si = OSI_SI(osi);

				if(UNLIKELY(!OSI_VALID(osi)))
					continue; // empty set: cost 0
			}

			for(;;){
				assert(SI_INST(si) < S_shape(S, S->G->shadows[s_edge->idx].group));

				inst = SI_INST(si);
				bitmap state = ss[SW_BMIDX(inst)] >> SW_BMOFF(si);

				if(UNLIKELY(!(state & SW_PASS))){
					if(LIKELY(state & SW_EVAL))
						goto shadow_penalty;

					w = &S->G->shadows[s_edge->idx];

					// given variables get the checkall optimization, so this is almost
					// always going to be computed
					if(LIKELY(s_edge->flags & W_COMPUTED)){
						if(UNLIKELY(!S->s_vstate[w->xi])){
							S_vexpandsp(S, w->xi);
							goto shadow_compute_chain;
						}

						ssp sp = S->s_vstate[w->xi][inst];

						if(UNLIKELY(!(sp.state & SP_CHAIN))){
shadow_compute_chain:
							X->w_edge = s_edge;
							X->w_si = si;
							X_i = w->xi;
							X_inst = inst;
							X_beta = MAX_COST;
							goto x_solve;

shadow_solved:
							{
								s_edge = X->w_edge;
								si = X->w_si;
								inst = SI_INST(si);
								w = &S->G->shadows[s_edge->idx];
								ss = S->s_sstate[s_edge->idx];
								goto shadow_compute;
							}

shadow_failed:
							{
								s_edge = X->w_edge;
								inst = SI_INST(X->w_si);
								ss = S->s_sstate[s_edge->idx];
								ss[SW_BMIDX(inst)] |= SW_EVAL << SW_BMOFF(inst);
								goto shadow_penalty;
							}
						}

						if(UNLIKELY(!(sp.state & SP_VALUE))){
shadow_compute:
							S_compute_value(S, w->xi, inst);
						}
					}else{
						bitmap *missing = S->s_vmstate[w->xi];

						if(UNLIKELY(missing == BM_ALL0))
							goto shadow_checkall;

						if(LIKELY(!missing || bm_isset(missing, inst))){
							J_vref(S, w->xi, inst);

							missing = S->s_vmstate[w->xi];
							if(LIKELY(missing == BM_ALL0))
								goto shadow_checkall;

							if(UNLIKELY(!missing || bm_isset(missing, inst)))
								JE_nvalue(S, w->xi, inst);
						}
					}

					// this instance check only (shadow->var is implicit ident)
					uint64_t pass = !!S_check1(S, w, inst);
					ss[SW_BMIDX(inst)] |= (SW_EVAL | pass) << SW_BMOFF(inst);

					if(!pass)
						goto shadow_penalty;
				}

				SI_NEXT(si);
			}

			continue;

shadow_checkall:
			S_checkspace(S, w, ss);

			if((ss[SW_BMIDX(inst)] >> SW_BMOFF(inst)) & SW_PASS)
				continue;

shadow_penalty:
			M_costS += s_edge->penalty;

			dv("%s:%u [%s:%u] -- penalty %s~%x [%s] [+%g] [%g/%g]\n",
					fhk_dsym(S->G, X->d_xi), X->d_xinst,
					fhk_dsym(S->G, X->d_mi), X->m_inst,
					fhk_dsym(S->G, s_edge->idx), s_edge->map,
					fhk_dsym(S->G, S->G->shadows[s_edge->idx].xi),
					s_edge->penalty,
					M_costS, M_betaS);

			if(LIKELY(M_costS > M_betaS))
				goto x_bound;

		} while(++s_edge != X->m.shadows);
	}

	// ---------------- computed parameters ----------------
	if(LIKELY(X->m.p_cparam != 0)){
		fhk_edge *p_edge = &X->m.params[X->m.p_cparam-1];
		X->where = XS_PARAM;

		do {
			ssiter si;
			ssp *xsp;
			float p_ssmax = 0;

			{
				xsp = S->s_vstate[p_edge->idx];
				opt_ssiter osi = p_ssiter(S, p_edge->map, X->m_inst);
				si = OSI_SI(osi);

				if(UNLIKELY(!OSI_VALID(osi)))
					continue; // empty set: cost 0

				X->p_edge = p_edge;
			}

			// cost is the max cost of the subset
			for(;;){
				assert(SI_INST(si) < S_shape(S, S->G->vars[p_edge->idx].group));

				ssp sp = xsp[SI_INST(si)];

				// sp->cost is always a valid low bound, no matter what the state,
				// and this won't skip cycles because sp->cost is negative
				if(UNLIKELY(M_costS + sp.cost > M_betaS)){
					assert(sp.cost > p_ssmax);
					M_costS += sp.cost;
					goto x_bound;
				}

				if(LIKELY(sp.state & SP_CHAIN)){
					// fast path: chain solved, cost is true cost
					p_ssmax = max(p_ssmax, sp.cost);
				}else{
					// chain not fully solved, recursion time
					X->p_ssmax = p_ssmax;
					X->p_si = si;
					X_i = p_edge->idx;
					X_inst = SI_INST(si);
					X_beta = M_betaS - M_costS;
					goto x_solve;

param_solved:       // solved under bound, we good
					{
						p_edge = X->p_edge;
						si = X->p_si;
						xsp = S->s_vstate[p_edge->idx];
						p_ssmax = max(X->p_ssmax, X_cost);

						assert(M_costS+p_ssmax <= M_betaS);
					}
				}

				SI_NEXT(si);
			}

			M_costS += p_ssmax;
			assert(M_costS <= M_betaS);

			dv("%s:%u [%s:%u] -- parameter %s~%x [+%g] [%g/%g]\n",
					fhk_dsym(S->G, X->d_xi), X->d_xinst,
					fhk_dsym(S->G, X->d_mi), X->m_inst,
					fhk_dsym(S->G, p_edge->idx), p_edge->map,
					p_ssmax,
					M_costS, M_betaS);

		} while(p_edge-- != X->m.params);
	}

	// we have made it here without crossing the threshold.
	// the cost is now exact and the chain is completely solved.
	{
		X_cost = costf((struct fhk_model *)&X->m, M_costS);
		X->m_sp->cost = X_cost;
		X->m_sp->state = SP_CHAIN;
		X->x_sp->state = SP_CHAIN_V(X->m_ei, X->m_inst);

		dv("%s:%u [%s:%u] -- chain solved [%g/%g]\n",
				fhk_dsym(S->G, X->d_xi), X->d_xinst,
				fhk_dsym(S->G, X->d_mi), X->m_inst,
				M_costS, M_betaS);

		goto x_chosen;
	}
}

static uint64_t S_check1(struct fhk_solver *S, struct fhk_shadow *w, xinst inst){
	static const void *L[] = { &&f32_ge, &&f32_le, &&f64_ge, &&f64_le, &&u8_m64 };
	void *vp = S->s_value[w->xi];

	goto *L[w->guard];

f32_ge: return ((float *)vp)[inst] >= w->arg.f32;
f32_le: return ((float *)vp)[inst] <= w->arg.f32;
f64_ge: return ((double *)vp)[inst] >= w->arg.f64;
f64_le: return ((double *)vp)[inst] <= w->arg.f64;
u8_m64: return !!((1ULL << ((uint8_t *)vp)[inst]) & w->arg.u64);
}

static void S_checkspace(struct fhk_solver *S, struct fhk_shadow *w, bitmap *state){
	int64_t n = S->g_shape[w->group];

	assert(n > 0);
	xinst inst = 0;

	do {
		uint64_t m = 2 * min((uint64_t)n, 32ull);
		uint64_t i = 0;
		n -= 32;
		bitmap sv = 0xaaaaaaaaaaaaaaaaull; // 10101...1010 (SP_EVAL set for each)

		do {
			// TODO: this can be written a lot better (inline the checks),
			// it's not very perf sensitive though, because shadows are cached
			sv |= ((uint64_t)!!S_check1(S, w, inst++)) << i;
			i += 2;
		} while(i < m);

		*state++ = sv;
	} while(n > 0);
}

AINLINE static void S_get_given(struct fhk_solver *S, xidx xi, xmap map, xinst inst){
	assert(V_GIVEN(&S->G->vars[xi]));

	// fast path, everything is already given, no need to look at the mapping
	if(LIKELY(S->s_vmstate[xi] == BM_ALL0))
		return;

	S_pexpand(S, map, inst);

	ssiter3p sip;
	xinst sinst, sinum;
	p_ssiter3(S, map, inst, &sip, &sinst, &sinum);

	if(UNLIKELY(!sinum))
		return;

	S_get_missing_si3ne(S, xi, sip, sinst, sinum);
}

static void S_get_missing_si3ne(struct fhk_solver *S, xidx xi, ssiter3p sip, xinst sinst,
		xinst sinum){

	assert(sinum > 0);

	bitmap *missing = S->s_vmstate[xi];

	if(UNLIKELY(!missing)){
		J_vref(S, xi, sinst);
		missing = S->s_vmstate[xi];
		if(LIKELY(missing == BM_ALL0))
			return;
		if(UNLIKELY(!missing || !bm_isset(missing, sinst)))
			JE_nvalue(S, xi, sinst);
	}

	for(;;){
		xinst end = sinst + sinum;

		while(bm_find1_iv(missing, &sinst, end)){
			J_vref(S, xi, sinst);
			if(UNLIKELY(!bm_isset(missing, sinst)))
				JE_nvalue(S, xi, sinst);
		}

		SI3_NEXTI(sip, sinst, sinum);
	}
}

// xi must be uncomputed with a chain, use S_get_value* if you're unsure
static void S_compute_value(struct fhk_solver *S, xidx xi, xinst inst){
	static_assert(sizeof(fhk_modcall) + 2*G_MAXEDGE*sizeof(fhk_mcedge) < (1 << SBUF_MIN_BITS));

	assert(V_COMPUTED(&S->G->vars[xi]));
	assert((S->s_vstate[xi][inst].state & (SP_CHAIN|SP_VALUE)) == SP_CHAIN);

	ssp *sp = &S->s_vstate[xi][inst];

	size_t m_ei = SP_CHAIN_EI(*sp);
	xinst m_inst = SP_CHAIN_INSTANCE(*sp);
	// it's safe to assign this here, this can't call itself recursively with the same sp since
	// that would imply a cycle in the selected chain.
	sp->state |= SP_VALUE;

	struct fhk_var *x = &S->G->vars[xi];
	fhk_edge m_e = x->models[m_ei];
	xidx mi = m_e.idx;
	struct fhk_model *m = &S->G->models[mi];
	ssp *m_sp = &S->s_mstate[mi][m_inst];

	if(UNLIKELY(m_sp->state & SP_VALUE))
		goto unpackvalue;

	assert(m_sp->state & SP_CHAIN);
	m_sp->state |= SP_VALUE;

	for(int64_t i=0;i<m->p_cparam;i++){
		fhk_edge e = m->params[i];
		opt_ssiter osi = p_ssiter(S, e.map, m_inst);
		if(UNLIKELY(!OSI_VALID(osi)))
			continue;
		S_get_computed_si(S, OSI_SI(osi), e.idx);
	}

	for(int64_t i=m->p_cparam;i<m->p_param;i++){
		fhk_edge e = m->params[i];
		S_get_given(S, e.idx, e.map, m_inst);
	}

	fhk_modcall *cm = sbuf_alloc_init(S, sizeof(*cm) + (m->p_param+m->p_return)*sizeof(*cm->edges));
	cm->mref.idx = mi;
	cm->mref.inst = m_inst;
	cm->np = m->p_param;
	cm->nr = m->p_return;

	for(int64_t i=0;i<m->p_param;i++){
		fhk_edge e = m->params[i];
		S_collect_mape(S, &cm->edges[e.a], e.idx, e.map, m_inst);
	}

	fhk_mcedge *mce = cm->edges + cm->np;
	assert(m->p_return > 0);

	if(LIKELY(m->flags & M_NORETBUF)){
		size_t r_ei = 0;

		do {
			fhk_edge e = m->returns[r_ei];
			S_vexpandvp(S, e.idx);
			p_directref(S, mce, e.idx, e.map, m_inst);
			mce++;
		} while(++r_ei < m->p_return);
	}else{
		// slow path, we collect to value bufs
		S_mexpandvp(S, mi);
		void **vbuf = RBUF(mi, m, m_inst);
		fhk_mcedge *mce = cm->edges + cm->np;
		size_t r_ei = 0;

		do {
			// use S_map_size here because return edges aren't necessarily expanded
			// (could have untouched variable with unknown group size)
			fhk_edge e = m->returns[r_ei];
			S_vexpandvp(S, e.idx);
			size_t sz = S->G->vars[e.idx].size;
			mce->n = S_map_size(S, e.map, m_inst);
			// 0 is so rare and arena_alloc handles it just fine, no need to special-case
			mce->p = vbuf[r_ei] = arena_alloc(S->arena, sz*mce->n, sz);
			mce++;
		} while(++r_ei < m->p_return);
	}

	J_modcall(S, cm);

unpackvalue:
	if(UNLIKELY(!(m->flags & M_NORETBUF))){
		// slow path, have to unpack return values.
		// S_compute_model has expanded the map.
		size_t sz = S->G->vars[xi].size;
		void **mp = RBUF(mi, m, m_inst);
		void *src = mp[m_e.a] + sz*p_packidxofe(S, m->returns[m_e.a].map, m_inst, inst);
		memcpy(S->s_value[xi] + sz*inst, src, sz);
	}

	dv("%s:%zu -- solved value [%s]\n", fhk_dsym(S->G, xi), inst, dstrvalue(S, xi, inst));
}

AINLINE static void S_get_computed_si(struct fhk_solver *S, ssiter it, xidx xi){
	ssp *sp = S->s_vstate[xi];

	for(;;){
		xinst inst = SI_INST(it);
		assert(sp[inst].state & SP_CHAIN);
		if(UNLIKELY(!(sp[inst].state & SP_VALUE)))
			S_compute_value(S, xi, inst);
		SI_NEXT(it);
	}
}

// every instance of xi in the mapping must have a value!
AINLINE static void S_collect_mape(struct fhk_solver *S, fhk_mcedge *e, xidx xi, xmap map,
		xinst m_inst){

	size_t sz = S->G->vars[xi].size;
	void *vp = S->s_value[xi];

	if(LIKELY(P_ISIDENT(map))){
		e->p = vp + sz*m_inst;
		e->n = 1;
		return;
	}

	if(LIKELY(P_ISSPACE(map))){
		assert(S->g_shape[map] != FHK_NINST); // must be expanded
		e->p = vp;
		e->n = S->g_shape[map];
		return;
	}

	assert(P_ISUSER(map));
	fhk_subset ss = S->u_map[map & P_UREF][m_inst];
	assert(ss != SS_UNDEF);

	if(LIKELY(SS_ISIVAL(ss))){
		e->p = vp + sz*PK_FIRST(SS_IIVAL(ss));
		e->n = PK_N1(SS_IIVAL(ss));
		return;
	}

	// complex subset, the slooooow path
	e->n = ss_csize(ss);
	e->p = S_sbuf_alloc(S, sz*e->n);

	ssiter3p ip;
	xinst inst, num;
	si3_complex(ss, &ip, &inst, &num);
	si3_collect_ne(e->p, vp, sz, ip, inst, num);
}

static void *S_sbuf_alloc(struct fhk_solver *S, size_t size){
	const uint64_t f_mask = (1ULL << SBUF_MIN_BITS) - 1;

	uint64_t oldbuf = __builtin_clzl(S->b_off | f_mask);
	uint64_t newbuf = __builtin_clzl((S->b_off + size) | f_mask);
	uint64_t idx = 64 - newbuf - SBUF_MIN_BITS;
	uint64_t start = (1ULL << (64 - newbuf)) & ~(1|(f_mask<<1));

	if(newbuf != oldbuf)
		S->b_off = start;

	assert(start <= S->b_off);
	assert(newbuf == __builtin_clzl((start+size)|f_mask));

	if(UNLIKELY(idx >= NUM_SBUF))
		JE_nbuf(S);

	if(UNLIKELY(!S->b_mem[idx]))
		S->b_mem[idx] = arena_alloc(S->arena, (1ULL << (65 - newbuf)) - start, SBUF_ALIGN);

	void *p = S->b_mem[idx] + (S->b_off - start);

	S->b_off += size;
	S->b_off = ALIGN(S->b_off, SBUF_ALIGN);

	return p;
}

AINLINE static void *sbuf_alloc_init(struct fhk_solver *S, size_t size){
	assert(size < (1ULL << SBUF_MIN_BITS));
	assert(S->b_mem[0]);
	S->b_off = size;
	return S->b_mem[0];
}

AINLINE static void p_directref(struct fhk_solver *S, fhk_mcedge *e, xidx xi, xmap map,
		xinst m_inst){

	void *vp = S->s_value[xi];

	if(LIKELY(P_ISIDENT(map))){
		e->p = vp + S->G->vars[xi].size * m_inst;
		e->n = 1;
	}else{
		assert(P_ISSPACE(map)); // user maps can't have direct refs (at least currently)
		e->p = vp;
		e->n = S->g_shape[map];
	}
}

AINLINE static opt_ssiter p_ssiter(struct fhk_solver *S, xmap map, xinst inst){
	if(LIKELY(P_ISIDENT(map)))
		return OSI_SIV(inst);

	if(LIKELY(P_ISSPACE(map))){
		assert(S->g_shape[map] != FHK_NINST);
		return OSI_V(!!S->g_shape[map], SI_SPACE(S->g_shape[map]));
	}

	assert(P_ISUSER(map));

	fhk_subset ss = S->u_map[map & P_UREF][inst];

	assert(ss != SS_UNDEF);

	if(LIKELY(SS_ISIVAL(ss)))
		return OSI_V(SS_NONEMPTY(ss), SI_RANGE(SS_IIVAL(ss)));
	else
		return OSI_SIV(SI_CFIRST(inst, map & P_UREF, SS_CIVAL(ss, 0)));
}

AINLINE static void p_ssiter3(struct fhk_solver *S, xmap map, xinst inst,
		ssiter3p *sip, xinst *sinst, xinst *sinum){

	if(LIKELY(P_ISIDENT(map))){
		*sip = 0;
		*sinst = inst;
		*sinum = 1;
		return;
	}

	if(LIKELY(P_ISSPACE(map))){
		assert(S->g_shape[map] != FHK_NINST);
		*sip = 0;
		*sinst = 0;
		*sinum = S->g_shape[map];
		return;
	}

	assert(P_ISUSER(map));
	si3_ss(S->u_map[map & P_UREF][inst], sip, sinst, sinum);
}

// note: this assumes `inst` is in the mapping.
// if eg. a usermap does something stupid, then this will return bogus values.
AINLINE static xinst p_packidxofe(struct fhk_solver *S, xmap map, xinst m_inst, xinst inst){
	// check this first, idents won't end up in retbufs so often
	if(LIKELY(P_ISSPACE(map)))
		return inst;

	if(LIKELY(P_ISIDENT(map)))
		return 0;

	assert(P_ISUSER(map));
	fhk_subset ss = S->u_map[map & P_UREF][m_inst];

	if(LIKELY(SS_ISIVAL(ss)))
		return inst - PK_FIRST(SS_IIVAL(ss));

	return ss_cpackidxof(ss, inst);
}

AINLINE static void si3_ss(fhk_subset ss, ssiter3p *sip, xinst *sinst, xinst *sinum){
	assert(ss != SS_UNDEF);

	uint32_t ival = LIKELY(SS_ISIVAL(ss)) ? SS_IIVAL(ss) : SS_CIVAL(ss, 0);
	*sip = ss;
	*sinst = PK_FIRST(ival);
	*sinum = LIKELY(ss) ? PK_N1(ival) : 0;
}

AINLINE static void si3_complex(fhk_subset ss, ssiter3p *sip, xinst *sinst, xinst *sinum){
	assert(SS_ISCOMPLEX(ss));

	uint32_t ival = SS_CIVAL(ss, 0);
	*sip = ss;
	*sinst = PK_FIRST(ival);
	*sinum = PK_N1(ival);
}

NOINLINE static ssiter si_cnexti(struct fhk_solver *S, ssiter it){
	// we are looking for the first interval such that PK_FIRST(pk) >= SS_INST(it),
	// and we know the low SI_HINT_BITS bits of it, so we binary search the block containing it.

	fhk_subset ss = S->u_map[SI_UREF(it)][SI_UREF_INST(it)];
	uint64_t n = SS_NUMI(ss);
	uint64_t b = n >> SI_HINT_BITS;
	uint64_t a = 0;
	uint32_t *p = SS_CPTR(ss);
	xinst prev = SI_INST(it);

	while(a < b){
		uint64_t i = a + ((b - a) >> 1);
		xinst first = PK_FIRST(p[((i+1) << SI_HINT_BITS)-1]);
		a = first < prev ? (i+1) : a;
		b = first < prev ? b : i;
	}

	uint64_t ivl = (a << SI_HINT_BITS) | SI_HINT(it);
	return SI_CNEXT(it, SI_HINT(it)+1, ivl == n, p[ivl]);
}

AINLINE static void si3_cnexti(ssiter3p *p, xinst *inst, xinst *num){
	*p += SI3P_IINCR;
	uint32_t pk = *SS_CPTR(*p);
	*inst = PK_FIRST(pk);
	*num = PK_N1(pk);
}

AINLINE static void si3_collect_ne(void *dest, void *src, size_t sz, ssiter3p ip, xinst inst,
		xinst num){

	assert(num > 0);

	for(;;){
		memcpy(dest, src+sz*inst, sz*num);
		dest += sz*num;
		SI3_NEXTI(ip, inst, num);
	}
}

static xinst ss_cpackidxof(fhk_subset ss, xinst inst){
	assert(SS_ISCOMPLEX(ss));

	uint32_t *pk = SS_CPTR(ss);
	size_t off = 0;

	for(;;){
		size_t i = PK_FIRST(*pk);
		size_t n = PK_N(*pk);

		if(inst - i <= n)
			return (inst - i) + off;

		off += n + 1;
		pk++;
	}
}

static size_t ss_csize(fhk_subset ss){
	assert(SS_ISCOMPLEX(ss));

	uint32_t *pk = SS_CPTR(ss);
	size_t num = SS_NUMI(ss);

	// num+1 total intervals, each length is n(ival)+1
	int64_t size = num+1;

	do {
		size -= (int16_t) (*pk >> 16);
		pk++;
	} while(num --> 0); // :)

	return size;
}

static bitmap *bm_alloc(struct fhk_solver *S, xinst num, bitmap init){
	size_t n = ALIGN(num, 64) / 8;
	bitmap *bm = arena_alloc(S->arena, sizeof(*bm)*n, alignof(*bm));
	for(size_t i=0;i<n;i++)
		bm[i] = init;
	return bm;
}

AINLINE static void bm_clear(bitmap *b, xinst inst){
	b[inst >> 6] &= ~(1ULL << (inst & 0x3f));
}

AINLINE static bool bm_isset(bitmap *b, xinst inst){
	return !!(b[inst >> 6] & (1ULL << (inst & 0x3f)));
}

AINLINE static bool bm_find1_iv(bitmap *bm, xinst *inst, xinst end){
	xinst pos = *inst;

	xinst nblocks = (end - pos) >> 6;
	xinst block = pos & ~0x3f;
	bm += pos >> 6;
	bitmap m = *bm & ((~0ull) << (pos & 0x3f));

	for(;;){
		if(m){
			xinst i = block + __builtin_ctz(m);
			*inst = i;
			return i < end;
		}

		if(!nblocks)
			return false;

		nblocks--;
		block += 64;
		m = *++bm;
	}
}

static ssp *ssp_alloc(struct fhk_solver *S, size_t n, ssp init){
	ssp *sp = arena_alloc(S->arena, n * sizeof(*sp), alignof(*sp));

	for(size_t i=0;i<n;i++)
		sp[i] = init;

	return sp;
}

static void r_copyroots(struct fhk_solver *S, size_t nv, struct fhk_req *req){
	S->r_nv = 0;

	for(size_t i=0;i<nv;i++){
		struct fhk_req r = req[i];

		if(UNLIKELY(!r.ss))
			continue;

		if(r.flags & FHKF_NPACK)
			S->s_value[r.idx] = r.buf;

		struct rootv *root = &S->r_roots[S->r_nv++];
		xinst inst, num;
		si3_ss(r.ss, &root->ip, &inst, &num);

		root->xi = r.idx;
		root->inst = inst;
		root->num = num;
		root->buf = r.buf;
	}
}

// for debugging use only -- same caveats as fhk_dsym, not suitable for multithreading,
// can overrun buffers, etc.
__attribute__((unused))
static const char *dstrvalue(struct fhk_solver *S, xidx xi, xinst inst){
	static char buf[128];

	typedef union { int32_t i32; float f32; } v32;
	typedef union { int64_t i64; double f64; } v64;

	if(ISVI(xi)){
		struct fhk_var *x = &S->G->vars[xi];
		if(V_GIVEN(x) && S->s_vmstate[xi] != BM_ALL0
				&& (!S->s_vmstate[xi] || (bm_isset(S->s_vmstate[xi], inst))))
			return "(no value given)";
		else if(V_COMPUTED(x) && (!S->s_vstate[xi] || !(S->s_vstate[xi][inst].state & SP_VALUE)))
			return "(no value computed)";

		void *vp = S->s_value[xi] + inst*x->size;

		switch(x->size){
			case 4: sprintf(buf, "u32: 0x%x f32: %f", ((v32*)vp)->i32, ((v32*)vp)->f32); break;
			case 8: sprintf(buf, "u64: 0x%lx f64: %f", ((v64*)vp)->i64, ((v64*)vp)->f64); break;
			default:
				strcpy(buf, "hex: 0x");
				for(size_t i=0;i<x->size;i++)
					sprintf(buf+strlen("hex: 0x")+2*i, "%x", ((uint8_t *)vp)[i]);
				buf[strlen("hex: 0x")+2*x->size] = 0;
		}
	}else{
		// TODO ISMI
		return "(model)";
	}

	return buf;
}
