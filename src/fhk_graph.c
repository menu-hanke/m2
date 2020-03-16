#include "bitmap.h"
#include "fhk.h"
#include "def.h"

#include <stdint.h>
#include <string.h>
#include <assert.h>

static int mark_isupp_v(struct fhk_graph *G, bm8 *vmask, bm8 *mmask, struct fhk_var *y);
static int mark_isupp_m(struct fhk_graph *G, bm8 *vmask, bm8 *mmask, struct fhk_model *m);
static uint16_t mask_lookup(uint16_t *idx, bm8 *mask, uint16_t n);
static uint16_t count_links_v(struct fhk_model **models, uint16_t n, bm8 *mmask);

void fhk_init(struct fhk_graph *G, bm8 *init_v){
	bm_copy((bm8 *) G->v_bitmaps, init_v, G->n_var);
	bm_zero((bm8 *) G->m_bitmaps, G->n_mod);
}

void fhk_graph_init(struct fhk_graph *G){
	assert(!G->n_var || (G->vars && G->v_bitmaps));
	assert(!G->n_mod || (G->models && G->m_bitmaps));

	fhk_subgraph_init(G);

	for(size_t i=0;i<G->n_var;i++)
		G->vars[i].uidx = i;

	for(size_t i=0;i<G->n_mod;i++)
		G->models[i].uidx = i;
}

void fhk_subgraph_init(struct fhk_graph *G){
	for(size_t i=0;i<G->n_var;i++){
		struct fhk_var *x = &G->vars[i];
		x->idx = i;
		x->bitmap = &G->v_bitmaps[i];
	}

	for(size_t i=0;i<G->n_mod;i++){
		struct fhk_model *m = &G->models[i];
		m->idx = i;
		m->bitmap = &G->m_bitmaps[i];
	}
}

void fhk_clear(struct fhk_graph *G){
	fhk_reset(G, (fhk_vbmap){.given=1}, (fhk_mbmap){.u8=0});
}

void fhk_reset(struct fhk_graph *G, fhk_vbmap vmask, fhk_mbmap mmask){
	bm_and8((bm8 *) G->v_bitmaps, G->n_var, vmask.u8);
	bm_and8((bm8 *) G->m_bitmaps, G->n_mod, mmask.u8);
}

void fhk_reset_mask(struct fhk_graph *G, bm8 *vmask, bm8 *mmask){
	bm_and((bm8 *) G->v_bitmaps, vmask, G->n_var);
	bm_and((bm8 *) G->m_bitmaps, mmask, G->n_mod);
}

void fhk_compute_reset_mask(struct fhk_graph *G, bm8 *vmask, bm8 *mmask){
	fhk_inv_supp(G, vmask, mmask);

	// Now vmask and mmask contain marked what we want to reset, so invert them
	bm_not(vmask, G->n_var);
	bm_not(mmask, G->n_mod);

	// Finally, these bits shouldn't be touched when stepping
	fhk_vbmap keep = { .given=1 };
	bm_or8(vmask, G->n_var, keep.u8);
}

// Compute inverse support of vmask, ie. mark all variables/models that vmask can be reached from
// (= can be changed by vmask)
void fhk_inv_supp(struct fhk_graph *G, bm8 *vmask, bm8 *mmask){
	fhk_clear(G);

	for(size_t i=0;i<G->n_var;i++)
		mark_isupp_v(G, vmask, mmask, &G->vars[i]);

	for(size_t i=0;i<G->n_mod;i++)
		mark_isupp_m(G, vmask, mmask, &G->models[i]);
}

size_t fhk_subgraph_size(struct fhk_graph *G, bm8 *vmask, bm8 *mmask){
	size_t nv = 0, nm = 0;
	size_t ex = 0;

	for(size_t i=0;i<G->n_var;i++){
		if(!vmask[i])
			continue;

		nv++;
		struct fhk_var *x = &G->vars[i];
		ex += sizeof(*x->models) * count_links_v(x->models, x->n_mod, mmask);
		ex += sizeof(*x->fwd_models) * count_links_v(x->fwd_models, x->n_fwd, mmask);
	}

	for(size_t i=0;i<G->n_mod;i++){
		if(!mmask[i])
			continue;

		nm++;
		struct fhk_model *m = &G->models[i];
		ex = ALIGN(ex, alignof(*m->checks));
		ex += sizeof(*m->checks) * m->n_check;
		ex += sizeof(*m->params) * m->n_param;
		ex += sizeof(*m->returns) * m->n_return;
		ex += sizeof(*m->rvals) * m->n_return;
	}

	return ALIGN(sizeof(*G), alignof(*G->vars))
		+ ALIGN(nv*sizeof(*G->vars), alignof(*G->models))
		+ ALIGN(nm*sizeof(*G->models), BITMAP_ALIGN)
		+ BITMAP_SIZE(nv)
		+ BITMAP_SIZE(nm)
		+ ex;
}

void fhk_copy_subgraph(void *dest, struct fhk_graph *G, bm8 *vmask, bm8 *mmask){
	// this is basically a ghetto arena.
	// the reason mem.h isn't used here is because I want fhk to be usable standalone,
	// so (apart from fhk_aux) I don't want to require an arena to use it.
	// (arguably this function could be a part of fhk_aux, but subgraphs are really useful,
	// and it would be really unfortunate if parts of the subgraph ended on different chunks
	// in the arena.)
	char *ap = dest;
#define ALLOC(sz, align)\
	({ ap = (char *) ALIGN((uintptr_t) ap, (align)); void *_r = ap; ap += (sz); _r; })

	// (1) compute popcounts & new indices
	uint16_t vind[G->n_var]; // old -> new vars
	uint16_t mind[G->n_mod]; // old -> new models

	size_t nv = mask_lookup(vind, vmask, G->n_var);
	size_t nm = mask_lookup(mind, mmask, G->n_mod);

	// (2) alloc vars & models + bitmaps
	struct fhk_graph *H = ALLOC(sizeof(*G), alignof(*G));
	memcpy(H, G, sizeof(*G)); // copy callbacks & udata
	H->n_var = nv;
	H->n_mod = nm;

	H->vars = ALLOC(nv * sizeof(*H->vars), alignof(*H->vars));
	H->models = ALLOC(nm * sizeof(*H->models), alignof(*H->models));
	H->v_bitmaps = ALLOC(BITMAP_SIZE(nv), BITMAP_ALIGN);
	H->m_bitmaps = ALLOC(BITMAP_SIZE(nm), BITMAP_ALIGN);

	// (3) assign indices & bitmap pointers
	fhk_subgraph_init(H);

	// (4) copy links
	for(size_t i=0;i<G->n_var;i++){
		if(!vmask[i])
			continue;

		struct fhk_var *xG = &G->vars[i];
		struct fhk_var *xH = &H->vars[vind[i]];

		xH->n_mod = 0;
		xH->models = (struct fhk_model **) ap;
		for(size_t j=0;j<xG->n_mod;j++){
			if(mmask[xG->models[j]->idx]){
				xH->models[xH->n_mod++] = &H->models[mind[xG->models[j]->idx]];
				ap += sizeof(*xH->models);
			}
		}

		xH->n_fwd = 0;
		xH->fwd_models = (struct fhk_model **) ap;
		for(size_t j=0;j<xG->n_fwd;j++){
			if(mmask[xG->fwd_models[j]->idx]){
				xH->fwd_models[xH->n_fwd++] = &H->models[mind[xG->fwd_models[j]->idx]];
				ap += sizeof(*xH->fwd_models);
			}
		}

		xH->udata = xG->udata;
		xH->uidx = xG->uidx;
	}

	for(size_t i=0;i<G->n_mod;i++){
		if(!mmask[i])
			continue;

		struct fhk_model *mG = &G->models[i];
		struct fhk_model *mH = &H->models[mind[i]];

		mH->n_check = mG->n_check;
		mH->checks = ALLOC(mH->n_check * sizeof(*mH->checks), alignof(*mH->checks));
		for(size_t j=0;j<mH->n_check;j++){
			memcpy(&mH->checks[j], &mG->checks[j], sizeof(*mH->checks));
			mH->checks[j].var = &H->vars[vind[mG->checks[j].var->idx]];
		}

		mH->n_param = mG->n_param;
		mH->params = ALLOC(mH->n_param * sizeof(*mH->params), alignof(*mH->params));
		for(size_t j=0;j<mH->n_param;j++)
			mH->params[j] = &H->vars[vind[mG->params[j]->idx]];

		mH->n_return = mG->n_return;
		mH->returns = ALLOC(mH->n_return * sizeof(*mH->returns), alignof(*mH->returns));
		mH->rvals = ALLOC(mH->n_return * sizeof(*mH->rvals), alignof(*mH->rvals));
		for(size_t j=0;j<mH->n_return;j++)
			mH->returns[j] = &H->vars[vind[mG->returns[j]->idx]];

		mH->k = mG->k;
		mH->c = mG->c;
		mH->ki = mG->ki;
		mH->ci = mG->ci;
		mH->udata = mG->udata;
		mH->uidx = mG->uidx;
	}

	dv("copied subgraph H<%p>(%zu, %zu) of G<%p>(%zu, %zu) (%zu/%zu bytes)\n",
			H, nv, nm, G, G->n_var, G->n_mod, ((uintptr_t) ap) - ((uintptr_t) dest),
			fhk_subgraph_size(G, vmask, mmask));

#undef ALLOC

	assert(((uintptr_t)ap) - ((uintptr_t)dest) <= fhk_subgraph_size(G, vmask, mmask));
}

void fhk_transfer_mask(bm8 *mH, bm8 *mG, bm8 *mask, size_t n){
	size_t iH = 0;

	for(size_t i=0;i<n;i++){
		if(mask[i])
			mH[iH++] = mG[i];
	}
}

void fhk_model_set_cost(struct fhk_model *m, double k, double c){
	m->k = (fhk_v2){k, k};
	m->c = (fhk_v2){c, c};
	// (cost - k) / c = ci*cost + ki : ci=1/c, ki=-k/c
	m->ki = -m->k/m->c;
	m->ci = 1/m->c;
}

void fhk_check_set_cost(struct fhk_check *c, double in, double out){
	assert(in <= out);
	c->cost[0] = in;
	c->cost[1] = out;
}

double fhk_solved_cost(struct fhk_model *m){
	assert(m->cost_bound[0] == m->cost_bound[1]);
	return m->cost_bound[0];
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

static uint16_t mask_lookup(uint16_t *idx, bm8 *mask, uint16_t n){
	uint16_t r = 0;
	for(uint16_t i=0;i<n;i++){
		if(mask[i])
			idx[i] = r++;
		else
			// make it hopefully segfault if we try to do something stupid
			idx[i] = ~0;
	}
	return r;
}

static uint16_t count_links_v(struct fhk_model **models, uint16_t n, bm8 *mmask){
	uint16_t r = 0;
	for(uint16_t i=0;i<n;i++)
		r += !!mmask[models[i]->idx];
	return r;
}
