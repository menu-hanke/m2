#include "bitmap.h"
#include "fhk.h"

static void mark_supp_v(bm8 *vmask, bm8 *mmask, struct fhk_var *y);
static void mark_supp_m(bm8 *vmask, bm8 *mmask, struct fhk_model *m);
static int mark_isupp_v(struct fhk_graph *G, bm8 *vmask, bm8 *mmask, struct fhk_var *y);
static int mark_isupp_m(struct fhk_graph *G, bm8 *vmask, bm8 *mmask, struct fhk_model *m);

void fhk_reset(struct fhk_graph *G, fhk_vbmap vmask, fhk_mbmap mmask){
	G->dirty = 0;
	bm_and8((bm8 *) G->v_bitmaps, G->n_var, vmask.u8);
	bm_and8((bm8 *) G->m_bitmaps, G->n_mod, mmask.u8);
}

void fhk_reset_mask(struct fhk_graph *G, bm8 *vmask, bm8 *mmask){
	G->dirty = 0;
	bm_and((bm8 *) G->v_bitmaps, vmask, G->n_var);
	bm_and((bm8 *) G->m_bitmaps, mmask, G->n_mod);
}

// Compute support of y, ie. all variables/models that can be reached from y
// (= can cause y to change)
void fhk_supp(bm8 *vmask, bm8 *mmask, struct fhk_var *y){
	mark_supp_v(vmask, mmask, y);
}

// Compute inverse support of vmask, ie. mark all variables/models that vmask can be reached from
// (= can be changed by vmask)
void fhk_inv_supp(struct fhk_graph *G, bm8 *vmask, bm8 *mmask){
	fhk_vbmap reset_v = { .mark=1 };
	fhk_mbmap reset_m = {0};
	fhk_reset(G, reset_v, reset_m);

	for(size_t i=0;i<G->n_var;i++)
		mark_isupp_v(G, vmask, mmask, &G->vars[i]);

	for(size_t i=0;i<G->n_mod;i++)
		mark_isupp_m(G, vmask, mmask, &G->models[i]);
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

	if(v->mark)
		return 0;

	// Unlike in fhk_solve, we don't need to reset the mark bit here,
	// no variable will ever need to be visited twice.
	// This also automatically takes care of cycles.
	v->mark = 1;

	int ret = 0;

	for(size_t i=0;i<y->n_mod;i++)
		ret = mark_isupp_m(G, vmask, mmask, y->models[i]) || ret;

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
