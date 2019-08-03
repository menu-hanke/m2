#include "bitmap.h"
#include "fhk.h"

static void mark_supp_v(bm8 *vmask, bm8 *mmask, struct fhk_var *y);
static void mark_supp_m(bm8 *vmask, bm8 *mmask, struct fhk_model *m);
static int mark_isupp_v(struct fhk_graph *G, bm8 *vmask, bm8 *mmask, struct fhk_var *y);
static int mark_isupp_m(struct fhk_graph *G, bm8 *vmask, bm8 *mmask, struct fhk_model *m);

void fhk_graph_init(struct fhk_graph *G){
	G->v_bitmaps = (fhk_vbmap *) bm_alloc(G->n_var);
	G->m_bitmaps = (fhk_mbmap *) bm_alloc(G->n_mod);

	fhk_reset(G, FHK_RESET_ALL);

	// TODO: precompute dependencies for resetting dependent variables of a set
}

void fhk_graph_destroy(struct fhk_graph *G){
	bm_free((bm8 *) G->v_bitmaps);
	bm_free((bm8 *) G->m_bitmaps);
}

void fhk_set_given(struct fhk_graph *G, struct fhk_var *x){
	fhk_vbmap given_mask = { .given = 1 };
	G->v_bitmaps[x->idx] = given_mask;
	x->mark.min_cost = 0;
	x->mark.max_cost = 0;
}

void fhk_set_solve(struct fhk_graph *G, struct fhk_var *y){
	fhk_vbmap solve_mask = { .solve = 1 };
	G->v_bitmaps[y->idx] = solve_mask;
}

void fhk_reset(struct fhk_graph *G, int what){
	// TODO: resetting a subset of the variables is usually needed in simulation

	fhk_mbmap reset_mask_m = {0};
	fhk_vbmap reset_mask_v = {
		.given = !(what & FHK_RESET_GIVEN),
		.solve = !(what & FHK_RESET_SOLVE)
	};

	bm_and((bm8 *) G->v_bitmaps, G->n_var, reset_mask_v.u8);
	bm_and((bm8 *) G->m_bitmaps, G->n_mod, reset_mask_m.u8);
}

// Compute support of y, ie. all variables that can cause y to change
void fhk_supp(bm8 *vmask, bm8 *mmask, struct fhk_var *y){
	mark_supp_v(vmask, mmask, y);
}

// Compute the inverse support of variables specified in vmask, starting from root y
// (ie. what set of variables can change when changing the set in  vmask).
// This can be done more efficiently by first constructing a list of backrefs from models
// and then following those, so we just use the simpler implementation to avoid
// memory allocation rituals.
void fhk_inv_supp(struct fhk_graph *G, bm8 *vmask, bm8 *mmask, struct fhk_var *y){
	fhk_reset(G, 0);
	mark_isupp_v(G, vmask, mmask, y);
}

static void mark_supp_v(bm8 *vmask, bm8 *mmask, struct fhk_var *y){
	if(vmask[y->idx])
		return;

	vmask[y->idx] = 0xff;

	for(size_t i=0;i<y->n_mod;i++)
		mark_supp_m(vmask, mmask, y->models[i]);
}

static void mark_supp_m(bm8 *vmask, bm8 *mmask, struct fhk_model *m){
	if(mmask[m->idx])
		return;

	mmask[m->idx] = 0xff;

	for(size_t i=0;i<m->n_param;i++)
		mark_supp_v(vmask, mmask, m->params[i]);

	for(size_t i=0;i<m->n_check;i++)
		mark_supp_v(vmask, mmask, m->checks[i].var);
}

static int mark_isupp_v(struct fhk_graph *G, bm8 *vmask, bm8 *mmask, struct fhk_var *y){
	if(vmask[y->idx])
		return 1;

	fhk_vbmap *v = &G->v_bitmaps[y->idx];

	// XXX: would be cleaner to have fhk_enter(var)/fhk_exit(var) functions or macros for this,
	// the same cycle detection is also repeated in fhk_solve.c
	if(v->solving)
		return 0;

	int ret = 0;
	v->solving = 1;

	for(size_t i=0;i<y->n_mod;i++)
		ret = mark_isupp_m(G, vmask, mmask, y->models[i]) || ret;

	v->solving = 0;

	if(ret)
		vmask[y->idx] = 0xff;

	return ret;
}

static int mark_isupp_m(struct fhk_graph *G, bm8 *vmask, bm8 *mmask, struct fhk_model *m){
	if(mmask[m->idx])
		return 1;

	int ret = 0;

	for(size_t i=0;i<m->n_param;i++)
		ret = mark_isupp_v(G, vmask, mmask, m->params[i]) || ret;

	for(size_t i=0;i<m->n_check;i++)
		ret = mark_isupp_v(G, vmask, mmask, m->checks[i].var) || ret;

	if(ret)
		mmask[m->idx] = 0xff;

	return ret;
}
