#include "fhk.h"
#include "graph.h"
#include "def.h"
#include "type.h"
#include "model/model.h"
#include "mappings.h"

#include <assert.h>

static int G_exec_model(struct fhk_graph *G, void *udata, pvalue *ret, pvalue *args);
static int G_resolve_var(struct fhk_graph *G, void *udata, pvalue *value);
static int G_fail_exec(struct fhk_graph *G, void *udata, pvalue *ret, pvalue *args);
static int G_fail_resolve(struct fhk_graph *G, void *udata, pvalue *value);
static const char *G_ddv(void *udata);
static const char *G_ddm(void *udata);

void fhkG_hook(struct fhk_graph *G, int what){
	if(what & (FHKG_HOOK_EXEC<<FHKG_HOOK_VAR))       G->resolve_var      = G_resolve_var;
	if(what & (FHKG_HOOK_AUTOFAIL<<FHKG_HOOK_VAR))   G->resolve_var      = G_fail_resolve;
	if(what & (FHKG_HOOK_EXEC<<FHKG_HOOK_MODEL))     G->exec_model       = G_exec_model;
	if(what & (FHKG_HOOK_AUTOFAIL<<FHKG_HOOK_MODEL)) G->exec_model       = G_fail_exec;
	if(what & (FHKG_HOOK_DEBUG<<FHKG_HOOK_VAR))      G->debug_desc_var   = G_ddv;
	if(what & (FHKG_HOOK_DEBUG<<FHKG_HOOK_MODEL))    G->debug_desc_model = G_ddm;
}

void fhkG_bindV(struct fhk_graph *G, unsigned idx, struct fhkG_mappingV *v){
	assert(idx < G->n_var);
	G->vars[idx].udata = v;
}

void fhkG_bindM(struct fhk_graph *G, unsigned idx, struct fhkG_mappingM *m){
	assert(idx < G->n_mod);
	G->models[idx].udata = m;
}

static int G_exec_model(struct fhk_graph *G, void *udata, pvalue *ret, pvalue *args){
	(void)G;
	struct model *m = ((struct fhkG_mappingM *) udata)->mod;
	return MODEL_CALL(m, ret, args);
}

#define XFLAGS(t) FHKG_FLAGS((t*)0)

__attribute__((flatten, no_sanitize("alignment")))
static int G_resolve_var(struct fhk_graph *G, void *udata, pvalue *value){
	(void)G;
	// clang fails at optimizing these flag tricks but it works on gcc
	// (and doesn't matter that much)

	XFLAGS(struct fhkG_mappingV) flags = ((struct fhkG_mappingV *) udata)->flags;

	tvalue *tv;

	switch(flags.resolve){
		case FHKG_MAP_INTERRUPT: {
#ifdef M2_USE_COROUTINES
			XFLAGS(struct fhkG_vintV) iflags = {.u64 = flags.u64};
			fhkG_interruptV(iflags.handle, value);
			return FHK_OK;
#else
			dv("Tried to read a coroutine variable but coroutine support not enabled\n");
			return -1;
#endif
		}

		/* mappings dispatch */
		case FHKM_MAP_DATA: tv = fhkM_data_read(udata); break;
		case FHKM_MAP_VEC:  tv = fhkM_vec_read(udata, flags.u64); break;
		/* FHKM_MAP_ENV: */

		// most likely unmapped
		// it's a bug if we go here
		default: UNREACHABLE();
	}

	*value = vpromote(*tv, flags.type);

	return FHK_OK;
}

static int G_fail_exec(struct fhk_graph *G, void *udata, pvalue *ret, pvalue *args){
	(void)G;
	(void)udata;
	(void)ret;
	(void)args;
	return -1;
}

static int G_fail_resolve(struct fhk_graph *G, void *udata, pvalue *value){	
	(void)G;
	(void)udata;
	(void)value;
	return -1;
}

#define NAME(x) ((x) ? (x)->name : "(unmapped)")

static const char *G_ddv(void *udata){
	return NAME((struct fhkG_mappingV *) udata);
}

static const char *G_ddm(void *udata){
	return NAME((struct fhkG_mappingM *) udata);
}
