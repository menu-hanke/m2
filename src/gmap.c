#include "gmap.h"
#include "type.h"
#include "sim_ds.h"
#include "fhk.h"
#include "bitmap.h"
#include "grid.h"
#include "vec.h"
#include "exec.h"
#include "def.h"

#include <stdlib.h>
#include <string.h>

static bool var_is_constant(tvalue to, unsigned reason, tvalue parm);
static bool env_is_visible(tvalue to, unsigned reason, tvalue parm);
static bool global_is_visible(tvalue to, unsigned reason, tvalue parm);

static const gmap_support SUPP_VAR = { global_is_visible, var_is_constant };
static const gmap_support SUPP_ENV = { env_is_visible, env_is_visible };
static const gmap_support SUPP_GLOBAL = { global_is_visible, global_is_visible };

static int G_model_exec(struct fhk_graph *G, void *udata, pvalue *ret, pvalue *args);
static int G_resolve_var(struct fhk_graph *G, void *udata, pvalue *value);
static const char *G_ddv(void *udata);
static const char *G_ddm(void *udata);

DD(static void debug_var_bind(struct fhk_graph *G, unsigned idx, struct gmap_any *g));

void gmap_hook(struct fhk_graph *G){
	for(size_t i=0;i<G->n_var;i++)
		gmap_unbind(G, i);
	for(size_t i=0;i<G->n_mod;i++)
		gmap_unbind_model(G, i);

	G->exec_model = G_model_exec;
	G->resolve_var = G_resolve_var;
	G->debug_desc_var = G_ddv;
	G->debug_desc_model = G_ddm;
}

void gmap_bind(struct fhk_graph *G, unsigned idx, struct gmap_any *g){
	DD(debug_var_bind(G, idx, g));
	G->vars[idx].udata = g;
}

void gmap_unbind(struct fhk_graph *G, unsigned idx){
	G->vars[idx].udata = NULL;
}

void gmap_bind_model(struct fhk_graph *G, unsigned idx, struct gmap_model *m){
	dv("%smap %s (%p) -> fhk model[%u]\n",
			G->models[idx].udata ? "(!) re" : "",
			m->name,
			m->f,
			idx
	);

	G->models[idx].udata = m;
}

void gmap_unbind_model(struct fhk_graph *G, unsigned idx){
	G->models[idx].udata = NULL;
}

void gmap_supp_obj_var(struct gmap_any *v, uint64_t objid){
	v->udata.u64 = objid;
	v->supp = &SUPP_VAR;
}

void gmap_supp_grid_env(struct gmap_any *v, uint64_t order){
	v->udata.u64 = order;
	v->supp = &SUPP_ENV;
}

void gmap_supp_global(struct gmap_any *v){
	v->supp = &SUPP_GLOBAL;
}

tvalue gmap_res_vec(void *v){
	struct gv_vec *vec = v;
	struct vec_band *band = V_BAND(vec->bind->vec, vec->target_band);
	return *(tvalue *) (V_DATA(band, vec->bind->idx) + vec->target_offset);
}

tvalue gmap_res_grid(void *v){
	struct gv_grid *g = v;
	gridpos z = grid_zoom_up(*g->bind, POSITION_ORDER, g->grid->order);
	return *(tvalue *) (((char *) grid_data(g->grid, z)) + g->target_offset);
}

tvalue gmap_res_data(void *v){
	struct gv_data *d = v;
	return *(tvalue *) *d->ref;
}

#define MARK_CALLBACK(cb)\
	for(size_t i=0;i<G->n_var;i++){\
		struct gmap_any *v = G->vars[i].udata;\
		if(v && cb(v->udata, reason, parm)){\
			vmask[i] = 0xff;\
		}\
	}\

void gmap_mark_visible(struct fhk_graph *G, bm8 *vmask, unsigned reason, tvalue parm){
	MARK_CALLBACK(v->supp->is_visible);
}

void gmap_mark_nonconstant(struct fhk_graph *G, bm8 *vmask, unsigned reason, tvalue parm){
	MARK_CALLBACK(!v->supp->is_constant);
}

#undef MARK_CALLBACK

void gmap_make_reset_masks(struct fhk_graph *G, bm8 *vmask, bm8 *mmask){
	fhk_inv_supp(G, vmask, mmask);

	// Now vmask and mmask contain marked what we want to reset, so invert them
	bm_not(vmask, G->n_var);
	bm_not(mmask, G->n_mod);

	// Finally, these bits shouldn't be touched when stepping
	// Note: (TODO) unstable vars should have the stable bit cleared
	fhk_vbmap keep = { .given=1, .stable=1 };
	bm_or8(vmask, G->n_var, keep.u8);
}

void gmap_init(struct fhk_graph *G, bm8 *init_v){
	bm_copy((bm8 *) G->v_bitmaps, init_v, G->n_var);
	bm_zero((bm8 *) G->m_bitmaps, G->n_mod);
}

void gmap_solve_vec(struct gmap_solver_vec_bind *bind, struct fhk_solver *solver, struct vec *vec){
	unsigned n = vec->n_used;

	if(!n)
		return;

	struct vec_ref *vbind = bind->v_bind;
	gridpos *zband = bind->z_band >= 0 ? V_BAND(vec, bind->z_band)->data : NULL;
	gridpos *zbind = bind->z_bind;

	dv("begin objvec solver on vec=%p vbind=%p zbind=%p\n", vec, vbind, zbind);

	if(vbind){
		vbind->vec = vec;
		vbind->idx = 0;
	}

	for(unsigned i=0;i<n;i++){
		dv("solver[%p]: %u/%u\n", vec, (i+1), n);

		if(vbind)
			vbind->idx = i;

		if(zbind)
			*zbind = *zband++;

		int r = fhk_solver_step(solver, i);
		assert(r == FHK_OK);
	}
}

static bool var_is_constant(tvalue to, unsigned reason, tvalue parm){
	return reason == GMAP_BIND_OBJECT && to.u64 != parm.u64;
}

static bool env_is_visible(tvalue to, unsigned reason, tvalue parm){
	return reason == GMAP_BIND_Z && to.u64 <= parm.u64;
}

static bool global_is_visible(tvalue to, unsigned reason, tvalue parm){
	(void)to;
	(void)reason;
	(void)parm;
	return true;
}

static int G_model_exec(struct fhk_graph *G, void *udata, pvalue *ret, pvalue *args){
	(void)G;
	return ex_exec(((struct gmap_model *) udata)->f, ret, args);
}

static int G_resolve_var(struct fhk_graph *G, void *udata, pvalue *value){
	(void)G;
	struct gmap_any *v = udata;
	tvalue t = v->resolve(v);
	*value = vpromote(t, v->target_type);
	return FHK_OK;
}

static const char *G_ddv(void *udata){
	return ((struct gmap_any *) udata)->name;
}

static const char *G_ddm(void *udata){
	return ((struct gmap_model *) udata)->name;
}

#ifdef DEBUG

static void debug_var_bind(struct fhk_graph *G, unsigned idx, struct gmap_any *g){
	char buf[1024];

	if(g->resolve == gmap_res_vec){
		struct gv_vec *v = (struct gv_vec *) g;
		snprintf(buf, sizeof(buf), "vec<bind=%p> band[%u]+%u",
				v->bind,
				v->target_band,
				v->target_offset
		);
	}else if(g->resolve == gmap_res_grid){
		struct gv_grid *v = (struct gv_grid *) g;
		snprintf(buf, sizeof(buf), "grid<%p, z=%p> +%u",
				v->grid,
				v->bind,
				v->target_offset
		);
	}else if(g->resolve == gmap_res_data){
		struct gv_data *v = (struct gv_data *) g;
		snprintf(buf, sizeof(buf), "ptr<%p>", v->ref);
	}else{
		snprintf(buf, sizeof(buf), "(resolve: %p)", g->resolve);
	}

	dv("%smap %s type=%u.%u : %s -> fhk var[%u]\n",
			G->vars[idx].udata ? "(!) re" : "",
			g->name,
			TYPE_BASE(g->target_type),
			TYPE_SIZE(g->target_type),
			buf,
			idx
	);
}

#endif
