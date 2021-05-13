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

#define MAX_COST       FLT_MAX     /* max cost, nothing above will be accepted */
#define MAX_STK        32          /* max working stack size (number of recursive variables) */
#define MAX_CANDSTK    256         /* max candidate stack size */
#define MAX_COSTACK    ((1<<16)+8) /* coroutine stack size (bytes, builtin only), must be 16n+8 */
#define COSTACK_ALIGN  16          /* coroutine stack alignment (bytes, builtin only), must be >= 16 */
#define NUM_SBUF       8           /* number of scratch buffer slots */
#define SBUF_MIN_BITS  16          /* first scratch buffer size */
#define SBUF_ALIGN     8           /* alignment of scratch mem allocations */
#define NUM_ROOTBUF    32           /* initial root queue size */

#if FHK_DEBUG
#define AINLINE
#else
#define AINLINE __attribute__((always_inline)) inline
#endif

#define NOINLINE __attribute((noinline))

// TODO: this will not work on big endian
#define SARG(...)        (((fhk_sarg){__VA_ARGS__}).u64 << 16)

// see fhk.h for subset representation
#define SS_UNDEF         ((fhk_subset)(~0ull))         /* all ones. this excludes any valid interval,
													    * because first should be non-negative */
#define SS_EMPTYSET      0x00010000                    /* empty set (remain=-1) */
#define SS_ISEMPTY(ss)   ((ss) == SS_EMPTYSET)         /* is it empty? */
#define SS_ISCOMPLEX(ss) ((int64_t)(ss) > SS_EMPTYSET) /* is it complex? (implies nonempty) */
#define SS_ISIVAL(ss)    ((int64_t)(ss) < 0)           /* is it a nonempty interval? */
#define SS_CPTR(ss)      ((uint32_t*)((ss) >> 16))     /* complex subset interval pointer */
#define SS_CIVAL(ss,n)   (SS_CPTR(ss)[n])              /* nth interval */
#define SS_CNUMI(ss)     ((ss) & 0xffff)               /* num of *remaining* ivals, 0 is valid */
#define SS_IIVAL(ss)     ((ssiter)(ss))                /* you can just use this as an iterator */
#define SS_PKIVAL(i,n)   (((~(n)) << 16) + (i) + 0xfffffffc00020000ull) /* pack interval */

#define PK_FIRST(pki)    ((pki) & 0xffff)              /* first instance in packed range */
#define PK_N(pki)        ((-((pki) >> 16)) & 0xffff)   /* exclusive (0xffff for empty set) */
#define PK_NS(pki)       (-((int32_t)(pki) >> 16))     /* signed version of PK_N */
#define PK_N1(pki)       ((1-((pki) >> 16)) & 0xffff)  /* inclusive (0 for empty set) */

// packed iterator representation. this is for iterating index-by-index.
// an iterator is always valid. use si_* functions for iterating.
//
// +------------+-------------+------------+----------+--------------+------------+
// | 8 (63..56) | 16 (55..40) | 7 (39..33) | 1 (32)   | 16 (31..16)  | 16 (15..0) |
// +------------+-------------+------------+----------+--------------+------------+
// | map        | map         | next       | last     | -remaining   | current    |
// | index      | instance    | interval   | interval | instances    | instance   |
// |            |             | hint       | marker   | in interval  |            |
// +------------+-------------+------------+----------+--------------+------------+
// |           complex iterators only                 |
// +--------------------------------------------------+
typedef uint64_t ssiter;

#define SI_HINT_BITS        (15-G_UMAPBITS)         /* num of low bits of interval to store */
#define SI_INST(it)         ((it) & 0xffff)         /* current instance */
#define SI_REM(it)          (((it) >> 16) & 0xffff) /* remaining counter */
#define SI_MAP(it)          (((int64_t)(it)) >> (64-G_UMAPBITS)) /* associated mapping (signed) */
#define SI_MAP_INST(it)     (((it) >> (48-G_UMAPBITS)) & 0xffff) /* instance of mapping */
#define SI_HINT(it)         (((it) >> 33) & ~((1<<SI_HINT_BITS)-1)) /* low bits of interval number */
#define SI_INCR             0x00010001              /* increment current and decrement remaining */
#define SI_NEXTMASK         0xffff0000              /* nonzero remaining? */
#define SI_NEXTIMASK        0x100000000ull          /* more intervals left? */

static_assert(G_UMAPBITS+G_INSTBITS+SI_HINT_BITS+1+G_INSTBITS+G_INSTBITS == 8*sizeof(ssiter));

// complex iterator construction
#define SI_CFIRST(map,inst,pki) ( \
		((ssiter)(map) << (64-G_UMAPBITS)) \
		| ((ssiter)(inst) << (48-G_UMAPBITS)) \
		| (pki) )

// next interval of complex iterator
#define SI_CNEXT(it,hint,last,pki) ( \
		((it) & ((~0ull) << (48-G_UMAPBITS))) \
		| ((((ssiter)(hint)) & ((1ULL<<SI_HINT_BITS)-1)) << 33) \
		| (pki) )

// unfortunately compilers generate confused code with an inline function so you're going
// to have to use this to iterate.
// place this at the end of your for(;;) loop
// notes: (1) this overwrites `it`, (2) this accesses `S`
#define SI_NEXT(it) \
	{ \
		if(LIKELY(it & SI_NEXTMASK)){ it += SI_INCR; continue; } \
		if(UNLIKELY(it & SI_NEXTIMASK)){ it = si_cnexti(S, it); continue; } \
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

// non-packed iterator representation.
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

#define SI3P_IINCR 0x3ffff /* decrement nonzero iv num, increment iv pointer by 4 */
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
#define SP_CHAIN_V(e,i)       (SP_EXPANDED|SP_CHAIN|((e)<<16)|(i)) /* chain always implies expanded */
#define SP_CHAIN_EI(sp)       (((sp).state >> 16) & 0xff)
#define SP_CHAIN_INSTANCE(sp) ((sp).state & 0xffff)
#define SP_DONEMASK           ((SP_CHAIN << 32) | 0x7fffffffull)
#define SP_UMAXCOST           ((union { uint32_t u32; float f; }){.f=MAX_COST}).u32
#define SP_DONE(sp)           (((sp).u64 & SP_DONEMASK) >= SP_UMAXCOST)
#define SP_MARK               ((union { uint32_t u32; float f; }){.u32=0x80800000}).f
#define SP_MARKED(sp)         ((sp).cost < 0)

typedef uint64_t bitmap;

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

#define ROOT_GIVEN   1

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
	ssiter m_si;
	ssp *m_fsp;
	fhk_idx m_i;
	uint8_t m_ei;
};

struct rootv {
	void *buf;
	fhk_idx xi;
	fhk_inst inst;
	fhk_inst end;
	uint8_t flags;
	// uint8_t unused
};

typedef union {
	fhk_subset *imap;
	fhk_subset kmap;
} anymap;

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
	void **s_value;            // value state
	anymap *s_mapstate;        // mapping state
	struct xstate x_state[MAX_STK]; // work stack
	struct xcand x_cand[MAX_CANDSTK]; // candidate stack
	uint64_t b_off;            // scratch alloc position
	void *b_mem[NUM_SBUF];     // scratch memory (for passing arguments outside solver)
	arena *arena;              // allocator
	uint16_t r_num;            // root queue position
	uint16_t r_size;           // root queue size
	fhk_inst bm0_size;         // size of interned all-0 bitmap
	// uint16_t unused
	struct rootv *r_buf;       // root queue
	bitmap *bm0_intern;        // interned all-0 bitmap
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
static void J_mapcall(struct fhk_solver *S, xmap map, xinst inst);
static void J_vref(struct fhk_solver *S, xidx xi, xinst inst);
static void J_modcall(struct fhk_solver *S, fhk_modcall *mc);

static void JE_maxdepth(struct fhk_solver *S, xidx xi, xinst inst);
static void JE_nyi(struct fhk_solver *S);
static void JE_nvalue(struct fhk_solver *S, xidx xi, xinst inst);
static void JE_nmap(struct fhk_solver *S, xmap idx, xinst inst);
static void JE_nbuf(struct fhk_solver *S);
static void JE_nchain(struct fhk_solver *S, xidx xi, xinst inst);

static void J_exit(struct fhk_solver *S, fhk_status status);

static void E_exit(struct fhk_solver *S, fhk_status status);

static void S_solve(struct fhk_solver *S);

static void S_vexpandbe(struct fhk_solver *S, xidx xi, xinst inst);
static void S_mexpandbe(struct fhk_solver *S, xidx mi, xinst inst);
static void S_vexpandsp(struct fhk_solver *S, xidx xi);
static void S_vexpandss(struct fhk_solver *S, xidx wi);
static void S_vexpandvp(struct fhk_solver *S, xidx xi);
static void S_mexpandsp(struct fhk_solver *S, xidx mi);
static void S_mexpandvp(struct fhk_solver *S, xidx mi);
static void S_expandmap(struct fhk_solver *S, xmap map, xinst inst);
static fhk_subset S_expandumap(struct fhk_solver *S, xmap map, xinst inst);
static xinst S_shape(struct fhk_solver *S, xgrp group);
static size_t S_map_size(struct fhk_solver *S, xmap map, xinst inst);

static void S_select_chain(struct fhk_solver *S, xidx xi, xinst inst);

static void S_checkscan(struct fhk_solver *S, bitmap *bm, struct fhk_shadow *w, xinst inst,
		xinst end);

static void S_get_given(struct fhk_solver *S, xidx xi, xmap map, xinst inst);
static bitmap *S_touch_vmstate(struct fhk_solver *S, xidx xi, xinst inst);
static void S_get_missingi(struct fhk_solver *S, xidx xi, xinst inst, xinst end, bitmap *missing);
static void S_get_given1(struct fhk_solver *S, xidx xi, xinst inst);
static void S_get_given_si3(struct fhk_solver *S, xidx xi, ssiter3p ip, xinst inst, xinst num);
static void S_get_giveni(struct fhk_solver *S, xidx xi, xinst inst, xinst end);

static void S_compute_value(struct fhk_solver *S, xidx xi, xinst inst);
static void S_get_computed_si(struct fhk_solver *S, ssiter it, xidx xi);

static void S_mapE_collect(struct fhk_solver *S, fhk_mcedge *e, xidx xi, xmap map, xinst m_inst);

static void *S_sbuf_alloc(struct fhk_solver *S, size_t size);

static void *sbuf_alloc_init(struct fhk_solver *S, size_t size);

static fhk_subset mapE_subset(struct fhk_solver *S, xmap map, xinst inst);
static void mapE_directref(struct fhk_solver *S, fhk_mcedge *e, xidx xi, xmap map, xinst m_inst);
static opt_ssiter mapE_ssiter(struct fhk_solver *S, xmap map, xinst inst);
static xinst mapE_indexof(struct fhk_solver *S, xmap map, xinst m_inst, xinst inst);

static xmap map_toext(struct fhk_solver *S, xmap map);
static xmap map_fromext(struct fhk_solver *S, xmap map);

static void si3_ss(fhk_subset ss, ssiter3p *sip, xinst *sinst, xinst *sinum);
static void si3_complex(fhk_subset ss, ssiter3p *sip, xinst *sinst, xinst *sinum);
static ssiter si_cnexti(struct fhk_solver *S, ssiter it);
static void si3_cnexti(ssiter3p *p, xinst *inst, xinst *num);
static void si3_collect_ne(void *dest, void *src, size_t sz, ssiter3p ip, xinst inst, xinst num);

static xinst ss_cindexof(fhk_subset ss, xinst inst);
static size_t ss_csize(fhk_subset ss);

static xinst scanv_computed(struct fhk_solver *S, xidx xi, xgrp group, xinst inst);
static xinst scanv_given(struct fhk_solver *S, xidx xi, xgrp group, xinst inst);

static bitmap *bm_alloc(struct fhk_solver *S, xinst n, bitmap init);
static bitmap *bm_getall0(struct fhk_solver *S, xinst n);
static void bm_cleari(bitmap *bm, xinst inst, xinst num);
static bool bm_isset(bitmap *b, xinst inst);
static bool bm_findi(bitmap *bm, xinst *inst, xinst end);

static ssp *ssp_alloc(struct fhk_solver *S, size_t n, ssp init);

static const char *dstrvalue(struct fhk_solver *S, xidx xi, xinst inst);

fhk_solver *fhk_create_solver(struct fhk_graph *G, arena *arena){
	// not a hard requirement, just makes the alloc code simpler.
	// if this is changed then aligning needs to be done more carefully.
	static_assert(alignof(struct fhk_solver) == alignof(void *));

	// lazy use of memset. change the init code if you change the constant.
	static_assert((uint64_t)SS_UNDEF == 0xffffffffffffffffull);

#if FHK_CO_BUILTIN
	// TODO: this should probably not allocate it on the arena, instead mmap a stack
	// with a guard page. now stack overflows can corrupt the arena.
	void *stack = arena_alloc(arena, MAX_COSTACK, COSTACK_ALIGN);
#endif
	
	struct fhk_solver *S = arena_alloc(arena, sizeof(void *)*(G->nx+G->nm)+sizeof(*S), alignof(*S));
	S = (void *)S + G->nm * sizeof(*S->s_mstate);
	S->s_value = G->nm + (void **) arena_alloc(arena, (G->nv+G->nm) * sizeof(*S->s_value),
			alignof(*S->s_value));
	S->s_mapstate = G->nimap + (anymap *) arena_alloc(arena,
			(G->nimap+G->nkmap) * sizeof(*S->s_mapstate), alignof(*S->s_mapstate));
	S->r_buf = arena_alloc(arena, NUM_ROOTBUF * sizeof(*S->r_buf), alignof(*S->r_buf));
	S->b_mem[0] = arena_alloc(arena, 1 << SBUF_MIN_BITS, SBUF_ALIGN);

	S->G = G;
	S->arena = arena;

#if FHK_CO_BUILTIN
	fhk_co_init(&S->C, stack, MAX_COSTACK, &S_solve);
#else
	fhk_co_init(&S->C, MAX_COSTACK, &S_solve);
#endif

	memset(S->s_mstate - G->nm, 0, G->nm * sizeof(*S->s_mstate));
	memset(S->s_vstate, 0, G->nx * sizeof(*S->s_vstate));
	memset(S->s_mapstate - G->nimap, 0xff, (G->nimap+G->nkmap) * sizeof(*S->s_mapstate));
	memset(S->s_value - G->nm, 0, (G->nv+G->nm) * sizeof(*S->s_value));
	memset(S->b_mem+1, 0, (NUM_SBUF-1) * sizeof(*S->b_mem));

	S->x_state->where = XS_DONE;
	S->x_state->x_cands = 0;
	S->x_state->x_ncand = 0;
	S->b_off = 0;
	S->r_num = 0;
	S->r_size = NUM_ROOTBUF;
	S->bm0_size = 0;

	return S;
}

static void fhkS_setrooti(struct fhk_solver *S, xidx xi, xinst inst, xinst num, void *buf,
		uint32_t flags){

	if(UNLIKELY(S->r_num == S->r_size)){
		// queue full, need to allocate a new one.
		// if the solver is currently working on roots, we wouldn't need to copy that interval.
		// but that's probably not a helpful optimization (the queue almost never needs
		// to grow, and even then the memcpy is cheap.)
		// since it needed to grow, there's probably a set with a lot of intervals, so we
		// grow it aggressively by 4x here.
		S->r_size <<= 2;
		struct rootv *rbuf = arena_alloc(S->arena, S->r_size*sizeof(*S->r_buf), alignof(*S->r_buf));
		memcpy(rbuf, S->r_buf, S->r_num*sizeof(*S->r_buf));
		S->r_buf = rbuf;
	}

	struct rootv *r = &S->r_buf[S->r_num++];

	r->buf = buf;
	r->xi = xi;
	r->inst = inst;
	r->end = inst + num;
	r->flags = flags;

	dv("%s:[%zu..%zu] -- (%u) solution root -> %p [%p]\n",
			fhk_dsym(S->G, xi),
			inst, inst+num-1,
			S->r_num-1,
			buf, S->s_value[xi]
	);
}

void fhkS_setroot(struct fhk_solver *S, fhk_idx xi, fhk_subset ss, void *buf){
	if(UNLIKELY(SS_ISEMPTY(ss)))
		return;

	struct fhk_var *x = &S->G->vars[xi];
	uint32_t flags = V_GIVEN(x) ? ROOT_GIVEN : 0;

	if(LIKELY(SS_ISIVAL(ss))){
		// if the subset is the entire space and we haven't allocated a value buffer yet,
		// then use buf directly as the buffer to save copies.
		// note: this means you must not modify buf as long as the solver is active
		if((uint32_t)S->s_mapstate[x->group].kmap == (uint32_t)ss && !S->s_value[xi])
			S->s_value[xi] = buf;

		xinst inst = PK_FIRST(ss);
		fhkS_setrooti(S, xi, inst, PK_N1(ss), buf, flags);
		return;
	}

	size_t size = x->size;

	ssiter3p ip;
	xinst inst, num;
	si3_complex(ss, &ip, &inst, &num);

	for(;;){
		fhkS_setrooti(S, xi, inst, num, buf, flags);
		buf += num*size;
		SI3_NEXTI(ip, inst, num);
	}
}

void fhkS_setshape(struct fhk_solver *S, fhk_grp group, fhk_inst shape){
	if(UNLIKELY(group >= S->G->ng)){
		E_exit(S, FHK_ERROR | SARG(.s_ei = FHKE_INVAL | E_META(1, G, group)));
		return;
	}

	if(UNLIKELY(shape > G_MAXINST)){
		E_exit(S, FHK_ERROR | SARG(.s_ei = FHKE_INVAL | E_META(1, G, group) | E_META(2, J, shape)));
		return;
	}

	if(UNLIKELY(S->s_mapstate[group].kmap != SS_UNDEF)){
		E_exit(S, FHK_ERROR | SARG(.s_ei = FHKE_OVERWRITE | E_META(1, G, group)));
		return;
	}

	dv("shape[%u] -> %u\n", group, shape);
	S->s_mapstate[group].kmap = shape ? SS_PKIVAL(0, shape) : SS_EMPTYSET;
}

void fhkS_setvaluei(struct fhk_solver *S, fhk_idx xi, fhk_inst inst, uint32_t n, void *vp){
	if(UNLIKELY(!n)) return;
	if(UNLIKELY(xi > S->G->nv)) goto fail;

	struct fhk_var *x = &S->G->vars[xi];
	fhk_subset space = S->s_mapstate[x->group].kmap;
	xinst shape = PK_N1(space);

	if(UNLIKELY(!V_GIVEN(&S->G->vars[xi]))) goto fail;
	if(UNLIKELY(space == SS_UNDEF)) goto fail;
	if(UNLIKELY(inst+n > shape)) goto fail;

	if((n-inst) == shape){
		if(UNLIKELY(S->s_vmstate[xi])) goto fail;

		// fast path: got all at once, don't copy, just take the pointer
		S->s_vmstate[xi] = bm_getall0(S, shape);
		S->s_value[xi] = vp;
	}else{
		if(UNLIKELY(S->s_vmstate[xi] && !bm_isset(S->s_vmstate[xi], inst))) goto fail;

		// just partial, now we have to copy

		if(UNLIKELY(!S->s_vmstate[xi]))
			S->s_vmstate[xi] = bm_alloc(S, shape, ~0ULL);

		if(UNLIKELY(!S->s_value[xi]))
			S->s_value[xi] = arena_alloc(S->arena, shape*x->size, x->size);

		bm_cleari(S->s_vmstate[xi], inst, n);
		memcpy(S->s_value[xi] + inst*x->size, vp, n*x->size);
	}

	dv("%s:[%u..%u] -- given values @ %p :: [%s]\n",
			fhk_dsym(S->G, xi),
			inst, inst+n-1,
			vp,
			dstrvalue(S, xi, inst)
	);

	return;

fail:
	E_exit(S, FHK_ERROR | SARG(.s_ei = FHKE_INVAL | E_META(1, I, xi) | E_META(2, J, inst)));
}

void fhkS_setmap(struct fhk_solver *S, fhk_extmap emap, fhk_inst inst, fhk_subset ss){
	if(UNLIKELY(emap < -S->G->nimap || emap >= S->G->nkmap)) goto fail;

	xmap map = map_fromext(S, emap);

	if(MAP_ISCONST(map)){
		if(UNLIKELY(S->s_mapstate[map].kmap != SS_UNDEF)) goto fail;
		S->s_mapstate[map].kmap = ss;
		return;
	}

	xgrp group = S->G->umap_assoc[map];
	fhk_subset space = S->s_mapstate[group].kmap;
	xinst num = PK_N1(space);
	if(UNLIKELY(space == SS_UNDEF)) goto fail;
	if(UNLIKELY(inst >= num)) goto fail;

	fhk_subset *imap = S->s_mapstate[map].imap;
	if(UNLIKELY(imap == (fhk_subset*)SS_UNDEF)){
		imap = arena_alloc(S->arena, num*sizeof(*imap), alignof(*imap));
		S->s_mapstate[map].imap = imap;
		for(xinst i=0;i<num;i++)
			imap[i] = SS_UNDEF;
	}else if(UNLIKELY(imap[inst] != SS_UNDEF)){
		goto fail;
	}

	imap[inst] = ss;
	return;

fail:
	E_exit(S, FHK_ERROR | SARG(.s_ei = FHKE_INVAL | E_META(1, P, emap) | E_META(2, J, inst)));
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
	fhk_subset ss = S->s_mapstate[group].kmap;
	return ss != SS_UNDEF ? PK_N1(ss) : FHK_NINST;
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
		if(!missing || bm_isset(missing, inst))
			return NULL;
	}

	return S->s_value[xi] + x->size*inst;
}

fhk_subset fhkI_umap(struct fhk_solver *S, fhk_extmap emap, fhk_inst inst){
	xmap map = map_fromext(S, emap);
	anymap ms = S->s_mapstate[map];
	if(ms.kmap == SS_UNDEF)
		return SS_UNDEF;
	return MAP_ISCONST(map) ? ms.kmap : ms.imap[inst];
}

struct fhk_graph *fhkI_G(struct fhk_solver *S){
	return S->G;
}

AINLINE static void J_shape(struct fhk_solver *S, xgrp group){
	dv("-> SHAPE   %lu\n", group);
	fhkJ_yield(&S->C, FHKS_SHAPE | SARG(.s_group=group));
}

AINLINE static void J_mapcall(struct fhk_solver *S, xmap map, xinst inst){
	dv("-> MAPCALL %ld:%lu\n", map, inst);
	fhkJ_yield(&S->C, FHKS_MAPCALL | SARG(.s_mapcall={.idx=map, .inst=inst}));
}

AINLINE static void J_vref(struct fhk_solver *S, xidx xi, xinst inst){
	dv("-> VREF    %s:%lu\n", fhk_dsym(S->G, xi), inst);
	fhkJ_yield(&S->C, FHKS_VREF | SARG(.s_vref={.idx=xi, .inst=inst}));
}

AINLINE static void J_modcall(struct fhk_solver *S, fhk_modcall *mc){
	dv("-> MODCALL %s:%u (%u->%u)\n", fhk_dsym(S->G, mc->mref.idx), mc->mref.inst, mc->np, mc->nr);
	fhkJ_yield(&S->C, FHKS_MODCALL | SARG(.s_modcall=mc));
}

__attribute__((cold, noreturn))
static void JE_maxdepth(struct fhk_solver *S, xidx xi, xinst inst){
	J_exit(S, FHK_ERROR | SARG(.s_ei = FHKE_DEPTH | E_META(1, I, xi) | E_META(2, J, inst)));
}

__attribute__((cold, noreturn))
static void JE_nyi(struct fhk_solver *S){
	J_exit(S, FHK_ERROR | SARG(.s_ei = FHKE_NYI));
}

__attribute__((cold, noreturn))
static void JE_nvalue(struct fhk_solver *S, xidx xi, xinst inst){
	J_exit(S, FHK_ERROR | SARG(.s_ei = FHKE_NVALUE | E_META(1, I, xi) | E_META(2, J, inst)));
}

__attribute__((cold, noreturn))
static void JE_nmap(struct fhk_solver *S, xmap idx, xinst inst){
	J_exit(S, FHK_ERROR | SARG(.s_ei = FHKE_NVALUE | E_META(1, P, idx) | E_META(2, J, inst)));
}

__attribute__((cold, noreturn))
static void JE_nbuf(struct fhk_solver *S){
	J_exit(S, FHK_ERROR | SARG(.s_ei = FHKE_MEM));
}

__attribute__((cold, noreturn))
static void JE_nchain(struct fhk_solver *S, xidx xi, xinst inst){
	J_exit(S, FHK_ERROR | SARG(.s_ei = FHKE_CHAIN | E_META(1, I, xi) | E_META(2, J, inst)));
}

__attribute__((noreturn))
static void J_exit(struct fhk_solver *S, fhk_status status){
#if FHK_CO_BUILTIN
	for(;;)
		fhkJ_yield(&S->C, status);
#else
	fhk_co_done(&S->C);
	fhkJ_yield(&S->C, status);
	__builtin_unreachable();
#endif
}

#if FHK_CO_BUILTIN
__attribute__((cold))
static void SE_exit(struct fhk_solver *S){
	J_exit(S, S->e_status);
}
#endif

__attribute__((cold))
static void E_exit(struct fhk_solver *S, fhk_status status){
#if FHK_CO_BUILTIN
	S->e_status = status;
	fhk_co_jmp(&S->C, &SE_exit);
#else
	S->C.status = status;
	fhk_co_done(&S->C);
#endif
}

static void S_solve(struct fhk_solver *S){
	for(;;){
		if(!S->r_num){
			fhkJ_yield(&S->C, FHK_OK);
			continue;
		}

		uint32_t num = S->r_num;
		struct rootv *roots = S->r_buf;

		// get given roots first, if someone asked for them.
		for(uint32_t i=0;i<num;i++){
			struct rootv *r = &roots[i];
			if(UNLIKELY(r->flags & ROOT_GIVEN))
				S_get_giveni(S, r->xi, r->inst, r->end);
		}

		// solve chains
		for(uint32_t i=0;i<num;i++){
			struct rootv *r = &roots[i];

			if(UNLIKELY(r->flags & ROOT_GIVEN))
				continue;

			S_vexpandsp(S, r->xi);
			xinst inst = r->inst;
			ssp *sp = S->s_vstate[r->xi] + inst;

			do {
				if(LIKELY(!SP_DONE(*sp)))
					S_select_chain(S, r->xi, inst);
				sp++;
			} while(++inst < r->end);
		}

		// compute values
		for(uint32_t i=0;i<num;i++){
			struct rootv *r = &roots[i];

			if(UNLIKELY(r->flags & ROOT_GIVEN))
				continue;

			xinst inst = r->inst;
			ssp *sp = S->s_vstate[r->xi] + inst;

			do {
				if(LIKELY(!(sp->state & SP_VALUE)))
					S_compute_value(S, r->xi, inst);
				sp++;
			} while(++inst < r->end);
		}

		// collect values
		for(uint32_t i=0;i<num;i++){
			struct rootv *r = &roots[i];
			struct fhk_var *x = &S->G->vars[r->xi];
			void *vp = S->s_value[r->xi] + r->inst*x->size;

			if(vp == r->buf)
				continue;

			memcpy(r->buf, vp, (r->end-r->inst)*x->size);
		}

		// done.
		S->r_num -= num;
		if(UNLIKELY(S->r_num))
			memcpy(S->r_buf, S->r_buf+num, S->r_num*sizeof(*S->r_buf));
	}
}

// expand backward edges of computed variable
static void S_vexpandbe(struct fhk_solver *S, xidx xi, xinst inst){
	struct fhk_var *x = &S->G->vars[xi];
	assert(V_COMPUTED(x));

	uint32_t i = 0;
	do {
		S_mexpandsp(S, x->models[i].idx);
		S_expandmap(S, x->models[i].map, inst);
	} while(++i < x->n_mod);
}

// expand backward edges of model
static void S_mexpandbe(struct fhk_solver *S, xidx mi, xinst inst){
	struct fhk_model *m = &S->G->models[mi];

	for(int32_t i=m->p_shadow;i;i++){
		S_vexpandss(S, m->shadows[i].idx);
		S_expandmap(S, m->shadows[i].map, inst);
	}

	for(int32_t i=0;i<m->p_cparam;i++){
		S_vexpandsp(S, m->params[i].idx);
		S_expandmap(S, m->params[i].map, inst);
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

AINLINE static void S_expandmap(struct fhk_solver *S, xmap map, xinst inst){
	if(LIKELY(map == MAP_IDENT))
		return;

	S_expandumap(S, map, inst);
}

static fhk_subset S_expandumap(struct fhk_solver *S, xmap map, xinst inst){
	assert(map != MAP_IDENT);

	anymap ms = S->s_mapstate[map];

	if(UNLIKELY(ms.kmap == SS_UNDEF)){
		if((uint64_t)map < S->G->ng)
			J_shape(S, map);
		else
			J_mapcall(S, map_toext(S, map), inst);

		ms = S->s_mapstate[map];

		if(UNLIKELY(ms.kmap == SS_UNDEF))
			JE_nmap(S, map, inst);

		if(LIKELY(MAP_ISCONST(map)))
			return ms.kmap;
	}else{
		if(LIKELY(MAP_ISCONST(map)))
			return ms.kmap;

		if(LIKELY(ms.imap[inst] != SS_UNDEF))
			return ms.imap[inst];

		J_mapcall(S, map_toext(S, map), inst);
	}

	if(UNLIKELY(ms.imap[inst] == SS_UNDEF))
		JE_nmap(S, map, inst);

	return ms.imap[inst];
}

AINLINE static xinst S_shape(struct fhk_solver *S, xgrp group){
	assert(group < S->G->ng);
	return PK_N1(S_expandumap(S, group, FHK_NINST));
}

AINLINE static size_t S_map_size(struct fhk_solver *S, xmap map, xinst inst){
	if(LIKELY(map == MAP_IDENT))
		return 1;

	fhk_subset ss = S_expandumap(S, map, inst);
	return LIKELY(!SS_ISCOMPLEX(ss)) ? PK_N1(ss) : ss_csize(ss);
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

		uint32_t cstart = (X-1)->x_cands + (X-1)->x_ncand;
		X->x_cands = cstart;

		if(UNLIKELY(cstart + x->n_mod >= MAX_CANDSTK))
			JE_maxdepth(S, X_i, X_inst);

		struct xcand *cand = &S->x_cand[cstart];
		uint32_t nc = 0;
		uint32_t ei = 0;

		do {
			opt_ssiter osi = mapE_ssiter(S, x->models[ei].map, X_inst);

			if(UNLIKELY(!OSI_VALID(osi)))
				continue;

			cand->m_ei = ei;
			cand->m_i = x->models[ei].idx;
			cand->m_si = OSI_SI(osi);
			cand->m_fsp = S->s_mstate[cand->m_i] + SI_INST(cand->m_si);
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
			// we get a lower bound for the model whose parameter we tried to solve.
			// however we *don't* get a useful low bound for the lower variable,
			// but that's ok, we will try another candidate and any exit will update
			// X->x_sp->cost.
			X->m_sp->cost = costf((struct fhk_model *)&X->m, X->m_costS + X_cost);
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
		struct xcand *cand = &S->x_cand[X->x_cands];
		struct xcand *m_end = &S->x_cand[X->x_cands + X->x_ncand];
		struct xcand *m_cand = NULL;
		xinst m_inst = 0;

		do {
			ssp *sp = cand->m_fsp;
			ssiter it = cand->m_si;

			assert(S->s_mapstate[S->G->models[cand->m_i].group].kmap != SS_UNDEF);

			for(;;){
				assert(SI_INST(it) <= PK_N(S->s_mapstate[S->G->models[cand->m_i].group].kmap));

				float cost = sp->cost;
				m_cand = cost < m_cost ? cand : m_cand;
				m_inst = cost < m_cost ? SI_INST(it) : m_inst;
				m_beta = min(m_beta, max(m_cost, cost));
				m_cost = min(m_cost, cost);

				if(UNLIKELY(it & SI_NEXTMASK)){
					sp++;
					it += SI_INCR;
					continue;
				}

				if(UNLIKELY(it & SI_NEXTIMASK)){
					it = si_cnexti(S, it);
					sp = &S->s_mstate[cand->m_i][SI_INST(it)];
					continue;
				}

				break;
			}	
		} while(++cand != m_end);

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
		X->m = *(struct xmodel_bw *) m;
		X->m_ei = m_cand->m_ei;
		X->m_inst = m_inst;
		X->m_sp = sp;
		X->m_beta = m_beta;
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
			xinst inst;

			{
				ss = S->s_sstate[s_edge->idx];
				opt_ssiter osi = mapE_ssiter(S, s_edge->map, X->m_inst);
				si = OSI_SI(osi);

				if(UNLIKELY(!OSI_VALID(osi)))
					continue; // empty set: no penalty
			}

			for(;;){
				assert(SI_INST(si) < S_shape(S, S->G->shadows[s_edge->idx].group));

				inst = SI_INST(si);
				bitmap state = ss[SW_BMIDX(inst)] >> SW_BMOFF(si);

				if(UNLIKELY(!(state & SW_PASS))){
					if(LIKELY(state & SW_EVAL))
						goto shadow_penalty;

					struct fhk_shadow *w = &S->G->shadows[s_edge->idx];
					xinst scanto;

					if(s_edge->flags & W_COMPUTED){
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

						scanto = scanv_computed(S, w->xi, w->group, inst+1);
					}else{
						S_get_given1(S, w->xi, inst);
						scanto = scanv_given(S, w->xi, w->group, inst+1);
					}

					S_checkscan(S, ss, w, inst, scanto);

					if(!((ss[SW_BMIDX(inst)] >> SW_BMOFF(inst)) & SW_PASS))
						goto shadow_penalty;
				}

				SI_NEXT(si);
			}

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
				opt_ssiter osi = mapE_ssiter(S, p_edge->map, X->m_inst);
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

static void S_checkscan(struct fhk_solver *S, bitmap *bm, struct fhk_shadow *w, xinst inst,
		xinst end){

	static const void *_label[]    = { &&f32_ge, &&f32_le, &&f64_ge, &&f64_le, &&u8_m64 };
	static const uint8_t _stride[] = { 4,        4,        8,        8,        1 };

	const void *L = _label[w->guard];
	size_t stride = _stride[w->guard];
	void *vp = S->s_value[w->xi] + stride*inst;
	bm += SW_BMIDX(inst);
	uint64_t offset = SW_BMOFF(inst);
	xinst num = end - inst;
	bitmap state = *bm;

	float f32 = w->arg.f32;
	double f64 = w->arg.f64;
	uint64_t u64 = w->arg.u64;
	uint64_t ok = 0;

	goto *L;

f32_ge: ok = *(float *)vp >= f32; goto next;
f32_le: ok = *(float *)vp <= f32; goto next;
f64_ge: ok = *(double *)vp >= f64; goto next;
f64_le: ok = *(double *)vp <= f64; goto next;
u8_m64: ok = !!((1ULL << *(uint8_t *)vp) & u64); goto next;

next:
	ok |= SW_EVAL;
	state |= ok << offset;

	if(!--num){
		*bm = state;
		return;
	}

	vp += stride;
	offset = (offset + 2) & 0x3f;

	if(!offset){
		*bm++ = state;
		state = *bm;
	}

	goto *L;
}

static void S_get_given(struct fhk_solver *S, xidx xi, xmap map, xinst inst){
	assert(V_GIVEN(&S->G->vars[xi]));

	if(LIKELY(map == MAP_IDENT)){
		S_get_given1(S, xi, inst);
		return;
	}

	// this is either a given parameter or we are collecting a given result.
	// either way, there is no guarantee that the map is expanded.
	fhk_subset ss = S_expandumap(S, map, inst);
	if(LIKELY(!SS_ISEMPTY(ss))){
		ssiter3p ip;
		xinst first, num;
		si3_ss(ss, &ip, &first, &num);
		S_get_given_si3(S, xi, ip, first, num);
	}	
}

AINLINE static bitmap *S_touch_vmstate(struct fhk_solver *S, xidx xi, xinst inst){
	bitmap *missing = S->s_vmstate[xi];

	if(LIKELY(missing))
		return missing;

	J_vref(S, xi, inst);

	missing = S->s_vmstate[xi];
	if(UNLIKELY(!missing))
		JE_nvalue(S, xi, inst);

	return missing;
}

AINLINE static void S_get_missingi(struct fhk_solver *S, xidx xi, xinst inst, xinst end,
		bitmap *missing){

	while(bm_findi(missing, &inst, end)){
		J_vref(S, xi, inst);
		if(UNLIKELY(bm_isset(missing, inst)))
			JE_nvalue(S, xi, inst);
	}
}

static void S_get_given1(struct fhk_solver *S, xidx xi, xinst inst){
	bitmap *missing = S_touch_vmstate(S, xi, inst);

	if(!bm_isset(missing, inst))
		return;

	J_vref(S, xi, inst);
	if(UNLIKELY(bm_isset(missing, inst)))
		JE_nvalue(S, xi, inst);
}

static void S_get_given_si3(struct fhk_solver *S, xidx xi, ssiter3p ip, xinst inst, xinst num){
	bitmap *missing = S_touch_vmstate(S, xi, inst);

	for(;;){
		S_get_missingi(S, xi, inst, inst+num, missing);
		SI3_NEXTI(ip, inst, num);
	}
}

static void S_get_giveni(struct fhk_solver *S, xidx xi, xinst inst, xinst end){
	S_get_missingi(S, xi, inst, end, S_touch_vmstate(S, xi, inst));
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

	for(int32_t i=0;i<m->p_cparam;i++){
		fhk_edge e = m->params[i];
		opt_ssiter osi = mapE_ssiter(S, e.map, m_inst);
		if(UNLIKELY(!OSI_VALID(osi)))
			continue;
		S_get_computed_si(S, OSI_SI(osi), e.idx);
	}

	for(int32_t i=m->p_cparam;i<m->p_param;i++){
		fhk_edge e = m->params[i];
		S_get_given(S, e.idx, e.map, m_inst);
	}

	fhk_modcall *cm = sbuf_alloc_init(S, sizeof(*cm) + (m->p_param+m->p_return)*sizeof(*cm->edges));
	cm->mref.idx = mi;
	cm->mref.inst = m_inst;
	cm->np = m->p_param;
	cm->nr = m->p_return;

	for(int32_t i=0;i<m->p_param;i++){
		fhk_edge e = m->params[i];
		S_mapE_collect(S, &cm->edges[e.ex], e.idx, e.map, m_inst);
	}

	fhk_mcedge *mce = cm->edges + cm->np;
	assert(m->p_return > 0);

	// TODO: you can compute noretbuf (for edges at least) easily at runtime, even for umaps
	if(LIKELY(m->flags & M_NORETBUF)){
		size_t r_ei = 0;

		do {
			fhk_edge e = m->returns[r_ei];
			// expanding value buffer also expands shape/space map
			S_vexpandvp(S, e.idx);
			mapE_directref(S, mce, e.idx, e.map, m_inst);
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
			// mce->n can be 0, no problem
			mce->n = S_map_size(S, e.map, m_inst);
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
		void *src = mp[m_e.ex] + sz*mapE_indexof(S, m->returns[m_e.ex].map, m_inst, inst);
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
AINLINE static void S_mapE_collect(struct fhk_solver *S, fhk_mcedge *e, xidx xi, xmap map,
		xinst m_inst){

	size_t sz = S->G->vars[xi].size;
	void *vp = S->s_value[xi];

	if(LIKELY(map == MAP_IDENT)){
		e->p = vp + sz*m_inst;
		e->n = 1;
		return;
	}

	fhk_subset ss = mapE_subset(S, map, m_inst);

	// this also handles the empty set (PK_N1(SS_EMPTYSET) = 0)
	if(LIKELY(!SS_ISCOMPLEX(ss))){
		e->p = vp + sz*PK_FIRST(ss);
		e->n = PK_N1(ss);
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

AINLINE static fhk_subset mapE_subset(struct fhk_solver *S, xmap map, xinst inst){
	assert(map != MAP_IDENT);
	anymap ms = S->s_mapstate[map];
	assert(!(MAP_ISNONCONST(map) && !ms.imap));
	fhk_subset ss = LIKELY(MAP_ISCONST(map)) ? ms.kmap : ms.imap[inst];
	assert(ss != SS_UNDEF);
	return ss;
}

AINLINE static void mapE_directref(struct fhk_solver *S, fhk_mcedge *e, xidx xi, xmap map,
		xinst m_inst){

	void *vp = S->s_value[xi];

	if(LIKELY(map == MAP_IDENT)){
		e->p = vp + S->G->vars[xi].size * m_inst;
		e->n = 1;
	}else{
		// user maps can't have direct refs (at least currently), so this is a space map
		// (and therefore starts from zero)
		assert((uint64_t)map < S->G->ng);
		e->p = vp;
		e->n = PK_N1(S->s_mapstate[map].kmap);
	}
}

AINLINE static opt_ssiter mapE_ssiter(struct fhk_solver *S, xmap map, xinst inst){
	if(LIKELY(map == MAP_IDENT))
		return OSI_SIV(inst);

	fhk_subset ss = mapE_subset(S, map, inst);

	if(LIKELY(!SS_ISCOMPLEX(ss)))
		return OSI_V(!SS_ISEMPTY(ss), SS_IIVAL(ss));
	else
		return OSI_SIV(SI_CFIRST(map, inst, SS_CIVAL(ss, 0)));
}

// note: this assumes `inst` is in the mapping.
// if eg. a usermap does something stupid, then this will return bogus values.
AINLINE static xinst mapE_indexof(struct fhk_solver *S, xmap map, xinst m_inst, xinst inst){
	if(map == MAP_IDENT)
		return 0;

	fhk_subset ss = mapE_subset(S, map, m_inst);

	// ss can not be empty, because by assumtion it contains `inst`.
	if(LIKELY(SS_ISIVAL(ss)))
		return inst - PK_FIRST(ss);

	return ss_cindexof(ss, inst);
}

AINLINE static xmap map_toext(struct fhk_solver *S, xmap map){
	return MAP_ISCONST(map) ? (map - S->G->ng) : map;
}

AINLINE static xmap map_fromext(struct fhk_solver *S, xmap map){
	return MAP_ISCONST(map) ? (map + S->G->ng) : map;
}

AINLINE static void si3_ss(fhk_subset ss, ssiter3p *sip, xinst *sinst, xinst *sinum){
	assert(ss != SS_UNDEF);

	uint32_t ival = UNLIKELY(SS_ISCOMPLEX(ss)) ? SS_CIVAL(ss, 0) : SS_IIVAL(ss);
	*sip = UNLIKELY(SS_ISCOMPLEX(ss)) ? ss : 0;
	*sinst = PK_FIRST(ival);
	*sinum = PK_N1(ival);
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
	
	fhk_subset ss = mapE_subset(S, SI_MAP(it), SI_MAP_INST(it));
	uint32_t n = SS_CNUMI(ss);
	uint32_t b = n >> SI_HINT_BITS;
	uint32_t a = 0;
	uint32_t *p = SS_CPTR(ss);
	xinst prev = SI_INST(it);

	while(a < b){
		uint32_t i = a + ((b - a) >> 1);
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

static xinst ss_cindexof(fhk_subset ss, xinst inst){
	assert(SS_ISCOMPLEX(ss));

	uint32_t *pk = SS_CPTR(ss);
	uint32_t off = 0;

	for(;;){
		uint32_t i = PK_FIRST(*pk);
		uint32_t n = PK_N(*pk);

		if(inst - i <= n)
			return (inst - i) + off;

		off += n + 1;
		pk++;
	}
}

static size_t ss_csize(fhk_subset ss){
	assert(SS_ISCOMPLEX(ss));

	uint32_t *pk = SS_CPTR(ss);
	size_t num = SS_CNUMI(ss);

	// num+1 total intervals, each length is n(ival)+1
	int64_t size = num+1;

	do {
		size -= (int16_t) (*pk >> 16);
		pk++;
	} while(num --> 0); // :)

	return size;
}

AINLINE static xinst scanv_computed(struct fhk_solver *S, xidx xi, xgrp group, xinst inst){
	ssp *sp = S->s_vstate[xi] + inst;
	xinst end = PK_N(S->s_mapstate[group].kmap);

	while(inst <= end){
		if(!(sp->state & SP_VALUE))
			break;
		inst++;
		sp++;
	}

	return inst;
}

AINLINE static xinst scanv_given(struct fhk_solver *S, xidx xi, xgrp group, xinst inst){
	xinst end = PK_N1(S->s_mapstate[group].kmap);
	return bm_findi(S->s_vmstate[xi], &inst, end) ? inst : end;
}

static bitmap *bm_alloc(struct fhk_solver *S, xinst num, bitmap init){
	size_t n = ALIGN(num, 64) / 8;
	bitmap *bm = arena_alloc(S->arena, sizeof(*bm)*n, alignof(*bm));
	for(size_t i=0;i<n;i++)
		bm[i] = init;
	return bm;
}

static bitmap *bm_getall0(struct fhk_solver *S, xinst n){
	// recycle all-0 bitmaps, they will never be written to
	if(LIKELY(S->bm0_size >= n))
		return S->bm0_intern;

	// PK_N is faster than PK_N1, so use zero-based counting here.
	// n must be >0, otherwise we would have returned
	int32_t num = n--;

	// make a large enough alloc to hold any currently known group size.
	// in particular, if all shapes are provided at the beginning, this will only
	// allocate one bitmap in the solver's lifetime.
	// note: we don't have to special-case empty sets here:
	//   * PK_N(SS_UNDEF) = 1
	//   * PK_N(SS_EMPTYSET) = -1
	for(int32_t i=0;i<S->G->ng;i++)
		num = max(num, PK_NS(S->s_mapstate[i].kmap));

	// back to one-based counting
	num++;

	S->bm0_size = ALIGN(num, 64);
	S->bm0_intern = bm_alloc(S, num, 0);
	return S->bm0_intern;
}

AINLINE static void bm_cleari(bitmap *bm, xinst inst, xinst num){
	assert(num > 0);

	// we can do better than the usual bit clearing method (create and apply a mask) here
	// (not that this function is in the hot path or anything, but it's a fun trick).
	// we know that all the bits we want to clear are ones.
	// what zeroes a repeated run of ones? addition!
	// there's 2 cases to consider here:
	//     (1) 111xxxxx
	//     (2) xx111xxx
	// case (1) is easy: just add 1 to the start of the run. case (2) requires a bit more
	// care: adding 1 to the start of the run is the same as zeroing the ones and adding
	// 1 after the end of the run, so we have to cancel that add

	bm = &bm[inst >> 6];

	bitmap m = *bm;
	xinst start = inst & 0x3f;
	xinst end = start + num;
	bitmap last = 1ULL << end;
	m += 1ULL << start;
	m -= end < 64 ? last : 0;
	*bm = m;

	xinst zeroed = 64 - start;
	int32_t left = num - zeroed;

	while(left > 0){
		m = *++bm;
		m++;
		last = 1ULL << left;
		m -= left < 64 ? last : 0;
		*bm = m;
		left -= 64;
	}
}

AINLINE static bool bm_isset(bitmap *b, xinst inst){
	return !!(b[inst >> 6] & (1ULL << (inst & 0x3f)));
}

AINLINE static bool bm_findi(bitmap *bm, xinst *inst, xinst end){
	xinst pos = *inst;

	xinst offset = pos & ~0x3f;
	bitmap *endbm = bm + (end >> 6);
	bm += pos >> 6;
	bitmap m = *bm & ((~0ull) << (pos & 0x3f));

	for(;;){
		if(m){
			xinst i = offset + __builtin_ctzl(m);
			*inst = i;
			return i < end;
		}

		if(bm == endbm)
			return false;

		offset += 64;
		m = *++bm;
	}
}

static ssp *ssp_alloc(struct fhk_solver *S, size_t n, ssp init){
	ssp *sp = arena_alloc(S->arena, n * sizeof(*sp), alignof(*sp));

	for(size_t i=0;i<n;i++)
		sp[i] = init;

	return sp;
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
		if(V_GIVEN(x) && (!S->s_vmstate[xi] || (bm_isset(S->s_vmstate[xi], inst))))
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
