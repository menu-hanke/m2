#include "bitmap.h"
#include "fhk.h"

void fhk_graph_init(struct fhk_graph *G){
	G->v_bitmaps = (struct fhk_vbmap *) bm_alloc(G->n_var);
	G->m_bitmaps = (struct fhk_mbmap *) bm_alloc(G->n_mod);

	fhk_reset(G, FHK_RESET_ALL);

	// TODO: precompute dependencies for resetting dependent variables of a set
}

void fhk_graph_destroy(struct fhk_graph *G){
	bm_free((bm8 *) G->v_bitmaps);
	bm_free((bm8 *) G->m_bitmaps);
}

void fhk_set_given(struct fhk_graph *G, struct fhk_var *x){
	struct fhk_vbmap given_mask = { .given = 1 };
	G->v_bitmaps[x->idx] = given_mask;
	x->mark.min_cost = 0;
	x->mark.max_cost = 0;
}

void fhk_set_solve(struct fhk_graph *G, struct fhk_var *y){
	struct fhk_vbmap solve_mask = { .solve = 1 };
	G->v_bitmaps[y->idx] = solve_mask;
}

void fhk_reset(struct fhk_graph *G, int what){
	// TODO: resetting a subset of the variables is usually needed in simulation

	struct fhk_mbmap reset_mask_m = {0};
	struct fhk_vbmap reset_mask_v = {
		.given = !(what & FHK_RESET_GIVEN),
		.solve = !(what & FHK_RESET_SOLVE)
	};

	bm_and((bm8 *) G->v_bitmaps, G->n_var, BM_U8(&reset_mask_v));
	bm_and((bm8 *) G->m_bitmaps, G->n_mod, BM_U8(&reset_mask_m));
}
