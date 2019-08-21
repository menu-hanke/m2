#include "gmap.h"
#include "fhk.h"
#include "bitmap.h"
#include "exec.h"
#include "world.h"
#include "def.h"

#include <stdlib.h>
#include <string.h>

static int v_is_reachable(struct gmap_any *to, gmap_change change);
static int v_is_supported(struct gmap_any *to, gmap_change change);

static void mark_callback(struct fhk_graph *G, bm8 *vmask,
		int (*cb)(struct gmap_any *, gmap_change), gmap_change change);

static pvalue var_resolve(struct gv_var *var);
static pvalue env_resolve(struct gv_env *env);
static pvalue global_resolve(struct gv_global *glob);
static pvalue virtual_resolve(struct gv_virtual *virt);

static int G_model_exec(struct fhk_graph *G, void *udata, pvalue *ret, pvalue *args);
static int G_resolve_var(struct fhk_graph *G, void *udata, pvalue *value);
static const char *G_ddv(void *udata);
static const char *G_ddm(void *udata);

static const char *map_type_name(unsigned type);

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
	G->vars[idx].udata = g;

	dv("map %s : %s (%s) -> fhk var[%u]\n",
			g->name,
			map_type_name(g->type.support_type),
			map_type_name(g->type.resolve_type),
			idx
	);
}

void gmap_unbind(struct fhk_graph *G, unsigned idx){
	G->vars[idx].udata = NULL;
}

void gmap_bind_model(struct fhk_graph *G, unsigned idx, struct gmap_model *m){
	G->models[idx].udata = m;

	dv("map %s (%p) -> fhk model[%u]\n", m->name, m->f, idx);
}

void gmap_unbind_model(struct fhk_graph *G, unsigned idx){
	G->models[idx].udata = NULL;
}

void gmap_mark_reachable(struct fhk_graph *G, bm8 *vmask, gmap_change change){
	mark_callback(G, vmask, v_is_reachable, change);
}

void gmap_mark_supported(struct fhk_graph *G, bm8 *vmask, gmap_change change){
	mark_callback(G, vmask, v_is_supported, change);
}

void gmap_make_reset_masks(struct fhk_graph *G, bm8 *vmask, bm8 *mmask){
	fhk_inv_supp(G, vmask, mmask);

	// Now vmask and mmask contain marked what we want to reset, so invert them
	bm_not(vmask, G->n_var);
	bm_not(mmask, G->n_mod);

	// Finally, these bits shouldn't be touched when stepping
	// Note: (TODO) unstable vars should have the stable bit cleared
	fhk_vbmap keep = { .given=1, .solve=1, .stable=1 };
	bm_or8(vmask, G->n_var, keep.u8);
}

void gmap_init(struct fhk_graph *G, bm8 *init_v){
	bm_copy((bm8 *) G->v_bitmaps, init_v, G->n_var);
	bm_zero((bm8 *) G->m_bitmaps, G->n_mod);
}

void gmap_reset(struct fhk_graph *G, bm8 *reset_v, bm8 *reset_m){
	bm_and((bm8 *) G->v_bitmaps, reset_v, G->n_var);
	bm_and((bm8 *) G->m_bitmaps, reset_m, G->n_mod);
}

void gmap_solve_vec(w_objvec *vec, void **res, struct gs_vec_args *arg){
	size_t n = vec->n_used;

	if(!n)
		return;

	w_objref *wbind = arg->wbind;
	gridpos *zbind = W_ISSPATIAL(arg->wobj) ? arg->zbind : NULL;
	gridpos *zband = zbind ? vec->bands[arg->wobj->z_band].data : NULL;

	dv("begin objvec solver on vec=%p wbind=%p zbind=%p\n", vec, wbind, zbind);

	if(wbind){
		wbind->vec = vec;
		wbind->idx = 0;
	}

	size_t nv = arg->nv;
	struct fhk_var **xs = arg->xs;
	struct fhk_graph *G = arg->G;
	bm8 *reset_v = arg->reset_v;
	bm8 *reset_m = arg->reset_m;

	for(size_t i=0;i<n;i++){
		gmap_reset(G, reset_v, reset_m);
		dv("solver[%p]: %zu/%zu\n", vec, (i+1), n);

		if(wbind)
			wbind->idx++;

		if(zbind)
			*zbind = *zband++;

		for(size_t j=0;j<nv;j++){
			int r = fhk_solve(G, xs[j]);
			assert(r == FHK_OK); // TODO error handling goes here
		}

		for(size_t j=0;j<nv;j++){
			type t = arg->types[j];
			tvalue v = vdemote(xs[j]->value, t);
			unsigned stride = tsize(t);
			memcpy(((char *)res[j]) + i*stride, &v, stride);
		}
	}
}

static int v_is_reachable(struct gmap_any *to, gmap_change change){
	switch(to->type.support_type){

		case GMAP_VAR:
			return change.type == GMAP_NEW_OBJECT
				&& change.objid == ((struct gv_var *) to)->objid;

		case GMAP_ENV:
			return change.type == GMAP_NEW_Z
				&& change.order <= ((struct gv_env *) to)->wenv->grid.order;

		case GMAP_GLOBAL:
			return 1;

		case GMAP_COMPUTED:
			return 0;

	}

	UNREACHABLE();
}

static int v_is_supported(struct gmap_any *to, gmap_change change){
	switch(to->type.support_type){

		case GMAP_VAR:
			return change.type == GMAP_NEW_OBJECT
				&& change.objid == ((struct gv_var *) to)->objid;

		case GMAP_ENV:
			return change.type == GMAP_NEW_Z
				&& change.order > ((struct gv_env *) to)->wenv->grid.order;

		case GMAP_GLOBAL:
		case GMAP_COMPUTED:
			return 0;
	}

	UNREACHABLE();
}

static void mark_callback(struct fhk_graph *G, bm8 *vmask,
		int (*cb)(struct gmap_any *, gmap_change), gmap_change change){
	
	for(size_t i=0;i<G->n_var;i++){
		void *var = G->vars[i].udata;
		if(var && cb(var, change))
			vmask[i] = 0xff;
	}
}

static pvalue var_resolve(struct gv_var *var){
	type t = var->wbind->vec->bands[var->varid].type;
	return vpromote(w_obj_read1(var->wbind, var->varid), t);
}

static pvalue env_resolve(struct gv_env *env){
	return vpromote(w_env_readpos(env->wenv, *env->zbind), env->wenv->type);
}

static pvalue global_resolve(struct gv_global *glob){
	w_global *wg = glob->wglob;
	return vpromote(wg->value, wg->type);
}

static pvalue virtual_resolve(struct gv_virtual *virt){
	return virt->resolve(virt->udata);
}

static int G_model_exec(struct fhk_graph *G, void *udata, pvalue *ret, pvalue *args){
	(void)G;
	return ex_exec(((struct gmap_model *) udata)->f, ret, args);
}

static int G_resolve_var(struct fhk_graph *G, void *udata, pvalue *value){
	(void)G;
	switch(((struct gmap_any *) udata)->type.resolve_type){
		case GMAP_VAR:     *value = var_resolve(udata); break;
		case GMAP_ENV:     *value = env_resolve(udata); break;
		case GMAP_GLOBAL:  *value = global_resolve(udata); break;
		case GMAP_VIRTUAL: *value = virtual_resolve(udata); break;
		default: UNREACHABLE();
	}

	return FHK_OK;
}

static const char *G_ddv(void *udata){
	return ((struct gmap_any *) udata)->name;
}

static const char *G_ddm(void *udata){
	return ((struct gmap_model *) udata)->name;
}

static const char *map_type_name(unsigned type){
	static const char *names[] = {
		[GMAP_VAR]      = "var",
		[GMAP_ENV]      = "env",
		[GMAP_GLOBAL]   = "global",
		[GMAP_VIRTUAL]  = "virtual",
		[GMAP_COMPUTED] = "computed"
	};

	if(type >= sizeof(names)/sizeof(char *))
		return "<invalid>";

	return names[type];
}
