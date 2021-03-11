#include "fhk.h"
#include "def.h"

#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <setjmp.h>
#include <math.h>
#include <assert.h>

#define xnonempty(p) (!P_ISUSER(p)) /* nonempty for nonempty space */
#define colorsym(c)  ((c) ? "< HIGH" : "> LOW ")

#define HSIZE     64                /* initial heap size */
#define GRAY      0                 /* lowest min cost possible */
#define BLACK     1                 /* lowest max cost possible */
#define COLOR(c)  (0x40 << (c))     /* color marker */
#define SELECTED  0x20              /* included in graph with full chain */
#define RETEDGE   0x10              /* return edge marker */

typedef uint16_t xcolor;

typedef union {
	struct {
		fhk_idx xi;
		xcolor color;
		float cost;
	};	
	uint64_t u64;
} hnode;
static_assert(__BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__); // TODO ?
static_assert(sizeof(hnode) == sizeof(uint64_t));

#define mknode(cost_,color_,xi_) ((hnode){.cost=(cost_),.color=(color_),.xi=(xi_)})

// nodes index from 1 to simplify index arithmetic. slot 0 is for metadata
typedef union {
	struct { uint32_t pos; uint32_t alloc; };
	hnode nodes[1];
} xheap;

typedef struct {
	uint8_t p_miss[2];
} mstate;

struct fhk_prune {
	struct fhk_graph *G;
	jmp_buf jmp_fail;
	xheap *heap;
	uint8_t *flags;
	fhk_cbound *bound;
	mstate *mstate;
	fhk_ei status;
};

static void prune_mark_given(struct fhk_prune *P);
static void prune_mark_skips(struct fhk_prune *P);
static void prune_init_mstate(struct fhk_prune *P);
static void prune_insert_given(struct fhk_prune *P);
static void prune_insert_constmods(struct fhk_prune *P);
static void prune_propagate(struct fhk_prune *P);
static void prune_bound_var(struct fhk_prune *P, xidx xi, float cost, xcolor color);
static void prune_bound_model(struct fhk_prune *P, xidx mi, xcolor color);
static void prune_insert_var(struct fhk_prune *P, xidx xi, float cost, xcolor color);
static void prune_mark_unreachable(struct fhk_prune *P);
static void prune_select(struct fhk_prune *P, xidx idx);
static void prune_mark_selects(struct fhk_prune *P);
static void prune_fail(struct fhk_prune *P, fhk_status status);

static xheap *heap_create();
static bool heap_insert(xheap **heap, hnode node);
static hnode heap_remove(xheap *H);
#define heap_empty(H) (!(H)->pos)

struct fhk_prune *fhk_create_prune(struct fhk_graph *G){
	struct fhk_prune *P = malloc(sizeof(*P));
	if(!P)
		return NULL;

	memset(P, 0, sizeof(*P));

	P->heap = heap_create();
	P->flags = malloc((G->nv + G->nm) * sizeof(*P->flags));
	P->bound = malloc((G->nv + G->nm) * sizeof(*P->bound));
	P->mstate = malloc(G->nm * sizeof(*P->mstate));
	if(!(P->heap && P->flags && P->bound && P->mstate))
		goto fail;

	memset(P->flags, 0, (G->nv + G->nm) * sizeof(*P->flags));
	memset(P->bound, 0, (G->nv + G->nm) * sizeof(*P->bound));
	P->flags += G->nm;
	P->mstate += G->nm;
	P->bound += G->nm;
	P->G = G;

	return P;

fail:
	if(P->heap) free(P->heap);
	if(P->flags) free(P->flags);
	if(P->bound) free(P->bound);
	if(P->mstate) free(P->mstate);
	free(P);
	return NULL;
}

void fhk_destroy_prune(struct fhk_prune *P){
	free(P->heap);
	free(P->flags - P->G->nm);
	free(P->bound - P->G->nm);
	free(P->mstate - P->G->nm);
	free(P);
}

uint8_t *fhk_prune_flags(struct fhk_prune *P){
	return P->flags;
}

fhk_cbound *fhk_prune_bounds(struct fhk_prune *P){
	return P->bound;
}

fhk_ei fhk_prune_run(struct fhk_prune *P){
	if(setjmp(P->jmp_fail))
		return P->status;

	prune_mark_given(P);
	prune_mark_skips(P);
	prune_init_mstate(P);
	prune_insert_given(P);
	prune_insert_constmods(P);
	prune_propagate(P);
	prune_mark_unreachable(P);
	prune_mark_selects(P);

	return FHK_OK;
}

static void prune_mark_given(struct fhk_prune *P){
	for(xidx i=0;i<P->G->nv;i++){
		if(P->flags[i] & FHKF_GIVEN){
			struct fhk_var *x = &P->G->vars[i];

			for(int64_t i=0;i<x->n_mod;i++)
				P->flags[x->models[i].idx] |= FHKF_SKIP;
		}
	}
}

static void prune_mark_skips(struct fhk_prune *P){
	for(xidx i=0;i<P->G->nv;i++){
		if(P->flags[i] & FHKF_SKIP){
			struct fhk_var *x = &P->G->vars[i];

			for(int64_t i=0;i<x->n_mod;i++)
				P->flags[x->models[i].idx] |= FHKF_SKIP;

			for(int64_t i=0;i<x->n_fwd;i++)
				P->flags[x->fwds[i].idx] |= FHKF_SKIP;
		}
	}
}

static void prune_init_mstate(struct fhk_prune *P){
	for(xidx i=0;i<P->G->nm;i++){
		struct fhk_model *m = &P->G->models[~i];
		mstate *ms = &P->mstate[~i];
		ms->p_miss[GRAY] = 0;
		ms->p_miss[BLACK] = m->p_param;

		for(int64_t j=0;j<m->p_param;j++)
			ms->p_miss[GRAY] += xnonempty(m->params[j].map);
	}
}

static void prune_insert_given(struct fhk_prune *P){
	for(xidx i=0;i<P->G->nv;i++){
		if(P->flags[i] & FHKF_GIVEN){
			if(P->flags[i] & FHKF_SKIP)
				prune_fail(P, FHKE_CHAIN | E_META(1, I, i));
			prune_insert_var(P, i, 0, GRAY);
			prune_insert_var(P, i, 0, BLACK);
		}
	}
}

static void prune_insert_constmods(struct fhk_prune *P){
	for(xidx i=0;i<P->G->nm;i++){
		if(!(P->flags[~i] & FHKF_SKIP)){
			mstate *ms = &P->mstate[~i];
			if(!ms->p_miss[GRAY]) prune_bound_model(P, ~i, GRAY);
			if(!ms->p_miss[BLACK]) prune_bound_model(P, ~i, BLACK);
		}
	}
}

static void prune_propagate(struct fhk_prune *P){
	while(!heap_empty(P->heap) > 0){
		hnode next = heap_remove(P->heap);
		prune_bound_var(P, next.xi, next.cost, next.color);
	}
}

static void prune_bound_var(struct fhk_prune *P, xidx xi, float cost, xcolor color){
	assert(!(P->flags[xi] & FHKF_SKIP));

	if(P->flags[xi] & COLOR(color))
		return;

	P->flags[xi] |= COLOR(color);

	dv("%s BOUND %s: %g\n", colorsym(color), fhk_dsym(P->G, xi), cost);

	P->bound[xi][color] = cost;
	struct fhk_var *x = &P->G->vars[xi];

	for(int64_t i=0;i<x->n_fwd;i++){
		fhk_edge *e = &x->fwds[i];
		if(color == GRAY && !xnonempty(e->map))
			continue;
		P->bound[e->idx][color] += cost;
		mstate *ms = &P->mstate[e->idx];
		if(!--ms->p_miss[color])
			prune_bound_model(P, e->idx, color);
	}
}

static void prune_bound_model(struct fhk_prune *P, xidx mi, xcolor color){
	if(P->flags[mi] & FHKF_SKIP)
		return;

	struct fhk_model *m = &P->G->models[mi];
	P->flags[mi] |= COLOR(color);
	float cost = P->bound[mi][color];

	for(int64_t i=m->p_shadow;i;i++){
		// note: in fact, this could be smarter. if the shadow is unreachable, then the
		// penalty will be always applied. however, detecting this would require two
		// passes over the graph and it never happens in real world graphs.
		if(color == BLACK || (P->flags[P->G->shadows[m->shadows[i].idx].xi] & FHKF_SKIP))
			cost += m->shadows[i].penalty;
	}

	dv("%s BOUND %s: %g (%g)\n", colorsym(color), fhk_dsym(P->G, mi), costf(m, cost), cost);

	cost = costf(m, cost);
	P->bound[mi][color] = cost;

	for(int64_t i=0;i<m->p_return;i++){
		fhk_edge *e = &m->returns[i];
		if(color == GRAY || xnonempty(e->map))
			prune_insert_var(P, e->idx, cost, color);
	}
}

static void prune_insert_var(struct fhk_prune *P, xidx xi, float cost, xcolor color){
	assert(!(P->flags[xi] & FHKF_SKIP));

	if(!heap_insert(&P->heap, mknode(cost, color, xi)))
		prune_fail(P, FHKE_MEM);
}

static void prune_mark_unreachable(struct fhk_prune *P){
	for(xidx i=-P->G->nm;i<P->G->nv;i++){
		assert(!((P->flags[i] & FHKF_SKIP) && (P->flags[i] & (COLOR(GRAY) | COLOR(BLACK)))));

		if(!(P->flags[i] & COLOR(GRAY))) P->bound[i][GRAY] = INFINITY;
		if(!(P->flags[i] & COLOR(BLACK))) P->bound[i][BLACK] = INFINITY;

		if(P->bound[i][GRAY] == INFINITY){
			dv("UNREACHABLE %s\n", fhk_dsym(P->G, i));
			P->flags[i] |= FHKF_SKIP;
		}
	}
}

static void prune_select(struct fhk_prune *P, xidx idx){
	if(P->flags[idx] & SELECTED)
		return;

	dv("SELECT %s: [%g, %g]\n", fhk_dsym(P->G, idx), P->bound[idx][0], P->bound[idx][1]);

	assert(!(P->flags[idx] & FHKF_SKIP));
	assert(P->bound[idx][GRAY] < INFINITY);

	P->flags[idx] |= SELECTED | FHKF_SELECT;

	if(ISVI(idx)){
		struct fhk_var *x = &P->G->vars[idx];
		float beta = P->bound[idx][BLACK];

		// (finite) black cost bound must be guaranteed in the pruned graph, so we must
		// select at least one model with black=beta (there could be multiple, but we
		// don't need all)
		bool needbeta = beta < INFINITY;

		for(int64_t i=0;i<x->n_mod;i++){
			xidx mi = x->models[i].idx;

			// this can't ever pick a skipped model, it will have gray=black=infinity
			if(P->bound[mi][GRAY] < beta || (needbeta && P->bound[mi][BLACK] == beta)){
				needbeta &= P->bound[mi][BLACK] > beta;
				prune_select(P, mi);
			}
		}
	}else{
		struct fhk_model *m = &P->G->models[idx];

		for(int64_t i=m->p_shadow;i;i++){
			xidx xi = P->G->shadows[m->shadows[i].idx].xi;
			if(!(P->flags[xi] & FHKF_SKIP))
				prune_select(P, xi);
		}

		for(int64_t i=0;i<m->p_param;i++)
			prune_select(P, m->params[i].idx);

		for(int64_t i=0;i<m->p_return;i++)
			P->flags[m->returns[i].idx] |= RETEDGE;
	}
}

static void prune_mark_selects(struct fhk_prune *P){
	for(xidx i=-P->G->nm;i<P->G->nv;i++){
		if(P->flags[i] & FHKF_SELECT){
			if(P->flags[i] & FHKF_SKIP)
				prune_fail(P, FHKE_CHAIN | E_META(1, I, i));
			prune_select(P, i);
		}	
	}

	for(xidx i=0;i<P->G->nv;i++){
		if(P->flags[i] & RETEDGE){
			assert(!(P->flags[i] & FHKF_SKIP));
			P->flags[i] |= FHKF_SELECT;
		}	
	}
}

static void prune_fail(struct fhk_prune *P, fhk_status status){
	P->status = status;
	longjmp(P->jmp_fail, 1);
}

static xheap *heap_create(){
	xheap *H = malloc((HSIZE+1) * sizeof(hnode));
	if(H){
		H->pos = 0;
		H->alloc = HSIZE;
	}
	return H;
}

static bool heap_insert(xheap **heap, hnode node){
	xheap *H = *heap;

	if(H->pos == H->alloc){
		uint32_t num = 2 * H->alloc;
		H = realloc(H, (num+1) * sizeof(hnode));
		if(!H)
			return false;
		*heap = H;
		H->alloc = num;
	}

	uint64_t pos = ++H->pos;

	while(pos > 1){
		uint64_t pp = pos / 2;
		hnode parent = H->nodes[pp];
		if(parent.u64 < node.u64)
			break;
		H->nodes[pos] = parent;
		pos = pp;
	}

	H->nodes[pos] = node;
	return true;
}

static hnode heap_remove(xheap *H){
	hnode root = H->nodes[1];
	hnode last = H->nodes[H->pos--];
	uint64_t pos = 1;

	for(;;){
		uint64_t minpos = pos;
		hnode minnode = last;

		if(2*pos <= H->pos && H->nodes[2*pos].u64 < minnode.u64){
			minpos = 2*pos;
			minnode = H->nodes[minpos];
		}

		if(2*pos+1 <= H->pos && H->nodes[2*pos+1].u64 < minnode.u64){
			minpos = 2*pos+1;
			minnode = H->nodes[minpos];
		}

		H->nodes[pos] = minnode;

		if(pos == minpos)
			return root;

		pos = minpos;
	}
}
