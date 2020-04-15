#include "fhk.h"
#include "graph.h"
#include "def.h"
#include "type.h"
#include "model/model.h"

// mappings
#include "vec.h"

#include <assert.h>

/* Hierarchical graph mapper.
 * Each solver graph is created from a root graph - the root graph must be kept alive.
 *
 * Root graph mapping:
 *     udata       -> NULL
 *     model udata -> model name
 *     var udata   -> var name
 *
 * Solver graph mapping:
 *     udata       -> root graph
 *     model udata -> model pointer
 *     var udata   -> tagged pointer:
 *                      8 bits: resolve    | 8 bits: type | 48 bits: info
 *             virtual  FHKG_MAP_INTERRUPT                  32 low bits: interrupt handle
 *                data  FHKM_MAP_TVALUE                     48 bits: tvalue pointer
 *                 vec  FHKM_MAP_VEC                        48 bits: fhkM_vecV pointer 
 * (TODO)         grid  FHKM_MAP_GRID                       48 bits: fhkM_gridV pointer
 */

#define ISROOT(G)   (!(G)->udata)
#define ISSOLVER(G) (!ISROOT(G))

#define TAGV(r,t,p) (((uint64_t)(r)<<56) | ((uint64_t)(t)<<48) | (uintptr_t)(p))
#define RESV(v)     ((uintptr_t)(v) >> 56)
#define TYPEV(v)    (((uintptr_t)(v) >> 48) & 0xff)
#define DATAV(v)    (((uintptr_t)(v)) & 0xffffffffffff)

enum {
	MAP_INTERRUPT = 0,
	MAP_PTR,
	MAP_VEC
	// MAP_GRID
};

static const char **nameV(struct fhk_graph *G, unsigned idx);
static const char **nameM(struct fhk_graph *G, unsigned idx);

static int G_exec_model(struct fhk_graph *G, void *udata, pvalue *ret, pvalue *args);
static int G_resolve_var(struct fhk_graph *G, void *udata, pvalue *value);
static int G_fail_exec(struct fhk_graph *G, void *udata, pvalue *ret, pvalue *args);
static int G_fail_resolve(struct fhk_graph *G, void *udata, pvalue *value);
static const char *G_ddv(struct fhk_graph *G, struct fhk_var *y);
static const char *G_ddm(struct fhk_graph *G, struct fhk_model *m);

void fhkG_hook_root(struct fhk_graph *G){
	G->udata = NULL;
	G->resolve_var = G_fail_resolve;
	G->exec_model = G_fail_exec;
	G->debug_desc_var = (fhk_desc) G_ddv;
	G->debug_desc_model = (fhk_desc) G_ddm;
}

void fhkG_hook_solver(struct fhk_graph *root, struct fhk_graph *G){
	G->udata = root;
	G->resolve_var = G_resolve_var;
	G->exec_model = G_exec_model;
	G->debug_desc_var = (fhk_desc) G_ddv;
	G->debug_desc_model = (fhk_desc) G_ddm;
}

struct fhk_graph *fhkG_root_graph(struct fhk_graph *G){
	return ISROOT(G) ? G : fhkG_root_graph(G->udata);
}

void fhkG_set_nameV(struct fhk_graph *G, unsigned idx, const char *name){
	*nameV(G, idx) = name;
}

const char *fhkG_nameV(struct fhk_graph *G, unsigned idx){
	return *nameV(G, idx);
}

void fhkG_set_nameM(struct fhk_graph *G, unsigned idx, const char *name){
	*nameM(G, idx) = name;
}

const char *fhkG_nameM(struct fhk_graph *G, unsigned idx){
	return *nameM(G, idx);
}

static const char **nameV(struct fhk_graph *G, unsigned idx){
	assert(idx < G->n_var);
	return ISROOT(G) ? (const char **) &G->vars[idx].udata : nameV(G->udata, G->vars[idx].uidx);
}

static const char **nameM(struct fhk_graph *G, unsigned idx){
	assert(idx < G->n_mod);
	return ISROOT(G) ? (const char **) &G->models[idx].udata : nameM(G->udata, G->models[idx].uidx);
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

static const char *G_ddv(struct fhk_graph *G, struct fhk_var *y){
	const char *name = fhkG_nameV(G, y->idx);
	return name ? name : "(unmapped)";
}

static const char *G_ddm(struct fhk_graph *G, struct fhk_model *m){
	const char *name = fhkG_nameM(G, m->idx);
	return name ? name : "(unmapped)";
}

// ----------- mappings implementation -------------

/* models */

// TODO: these could actually be copied from the root graph
void fhkM_mapM(struct fhk_graph *G, unsigned idx, struct model *m){
	G->models[idx].udata = m;
}

static int G_exec_model(struct fhk_graph *G, void *udata, pvalue *ret, pvalue *args){
	(void)G;
	assert(ISSOLVER(G));

	return MODEL_CALL((struct model *) udata, ret, args);
}

/* vars */

void fhkM_mapV(struct fhk_graph *G, unsigned idx, fhkG_mapV v){
	G->vars[idx].udata = (void *) v;
}

unsigned fhkM_mapV_type(fhkG_mapV v){
	return TYPEV(v);
}

fhkG_mapV fhkM_pack_intV(unsigned type, fhkG_handle handle){
	return TAGV(MAP_INTERRUPT, type, handle);
}

fhkG_mapV fhkM_pack_ptrV(unsigned type, void *p){
	return TAGV(MAP_PTR, type, p);
}

fhkG_mapV fhkM_pack_vecV(unsigned type, struct fhkM_vecV *v){
	return TAGV(MAP_VEC, type, v);
}

static tvalue *read_vecV(struct fhkM_vecV *v){
	struct vec *vec = *v->vec;
	unsigned idx = *v->idx;
	void *band = vec->bands[v->band];
	return (tvalue *) (((char *) band) + (v->stride * idx + v->offset));
}

__attribute__((flatten, no_sanitize("alignment")))
static int G_resolve_var(struct fhk_graph *G, void *udata, pvalue *value){
	(void)G;
	assert(ISSOLVER(G));

	tvalue *tv;

	switch(RESV(udata)){
		case MAP_INTERRUPT:
#ifdef M2_USE_COROUTINES
			fhkG_interruptV((fhkG_handle) DATAV(udata), value);
			return FHK_OK;
#else
			dv("Tried to read a coroutine variable but coroutine support not enabled\n");
			return -1;
#endif

		case MAP_PTR: tv = (tvalue *) DATAV(udata); break;
		case MAP_VEC: tv = read_vecV((struct fhkM_vecV *) DATAV(udata)); break;
		/* MAP_GRID: */

		// most likely unmapped
		// it's a bug if we go here
		default: UNREACHABLE();
	}

	*value = vpromote(*tv, TYPEV(udata));
	return FHK_OK;
}

/* iterators (this could probably be in a different file?) */

static bool iter_range_begin(struct fhkM_iter_range *iv){
	iv->idx = 0;
	return iv->len > 0;
}

static bool iter_range_next(struct fhkM_iter_range *iv){
	return ++iv->idx < iv->len;
}

void fhkM_range_init(struct fhkM_iter_range *iv){
	iv->iter.begin = (bool (*)(void *)) iter_range_begin;
	iv->iter.next = (bool (*)(void *)) iter_range_next;
}
