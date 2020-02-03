#include "gmap.h"
#include "gsolve.h"
#include "type.h"
#include "fhk.h"
#include "bitmap.h"
#include "grid.h"
#include "vec.h"
#include "def.h"
#include "model/model.h"

#include <stdlib.h>
#include <string.h>
#include <assert.h>

// these checks are just for debugging
#define IS_MAINGRAPH(G) (!(G)->udata)
#define IS_SUBGRAPH(G)  (!(IS_MAINGRAPH(G)))

static int G_model_exec(struct fhk_graph *G, void *udata, pvalue *ret, pvalue *args);
static int G_resolve_var(struct fhk_graph *G, void *udata, pvalue *value);
static inline tvalue resv_vec(struct gv_vec *v, uint64_t f);
static inline tvalue resv_grid(struct gv_grid *g, uint64_t f);
static inline tvalue resv_data(struct gv_data *d);

static int G_fail_exec(struct fhk_graph *G, void *udata, pvalue *ret, pvalue *args);
static int G_fail_resolve(struct fhk_graph *G, void *udata, pvalue *value);

static const char *G_ddv(void *udata);
static const char *G_ddm(void *udata);

DD(static void debug_var_bind(struct fhk_graph *G, unsigned idx, struct gv_any *v));

void gmap_hook_main(struct fhk_graph *G){
	for(size_t i=0;i<G->n_var;i++)
		gmap_unbind(G, i);
	for(size_t i=0;i<G->n_mod;i++)
		gmap_unbind_model(G, i);

	G->udata = NULL;
	G->exec_model = G_fail_exec;
	G->resolve_var = G_fail_resolve;
	G->debug_desc_var = G_ddv;
	G->debug_desc_model = G_ddm;
}

void gmap_hook_subgraph(struct fhk_graph *G, struct fhk_graph *H){
	H->udata = G;
	H->exec_model = G_model_exec;
	H->resolve_var = G_resolve_var;
}

void gmap_bind(struct fhk_graph *G, unsigned idx, struct gv_any *v){
	DD(debug_var_bind(G, idx, v));
	G->vars[idx].udata = v;
}

void gmap_unbind(struct fhk_graph *G, unsigned idx){
	G->vars[idx].udata = NULL;
}

void gmap_bind_model(struct fhk_graph *G, unsigned idx, struct gmap_model *m){
	assert(IS_MAINGRAPH(G));
	dv("%smap %s (%p) -> fhk model[%u]\n",
			G->models[idx].udata ? "(!) re" : "",
			m->name,
			m->mod,
			idx
	);

	G->models[idx].udata = m;
}

void gmap_unbind_model(struct fhk_graph *G, unsigned idx){
	G->models[idx].udata = NULL;
}

static int G_model_exec(struct fhk_graph *G, void *udata, pvalue *ret, pvalue *args){
	(void)G;
	assert(IS_SUBGRAPH(G));
	struct model *m = ((struct gmap_model *) udata)->mod;
	return MODEL_CALL(m, ret, args);
}

#define FLAGS(v)  typeof((v)->flags)
#define XFLAGS(t) FLAGS((t*)0)

static int G_resolve_var(struct fhk_graph *G, void *udata, pvalue *value){
	(void)G;
	assert(IS_SUBGRAPH(G));

	XFLAGS(struct gv_any) flags = ((struct gv_any *) udata)->flags;

	switch(flags.rtype){
		case GMAP_VEC: *value = vpromote(resv_vec(udata, flags.u64), flags.vtype); break;
		case GMAP_ENV: *value = vpromote(resv_grid(udata, flags.u64), flags.vtype); break;
		case GMAP_DATA: *value = vpromote(resv_data(udata), flags.vtype); break;
#ifdef M2_SOLVER_INTERRUPTS
		case GMAP_INTERRUPT: {
				XFLAGS(struct gv_int) iflags = {.u64 = flags.u64};
				gs_intv(iflags.handle, value);
			}
			break;
#endif
		default: UNREACHABLE();
	}

	return FHK_OK;
}

__attribute__((no_sanitize("alignment")))
static inline tvalue resv_vec(struct gv_vec *v, uint64_t f){
	FLAGS(v) flags = {.u64 = f};
	struct vec *vec = *v->v_bind;
	unsigned idx = *v->idx_bind;
	void *band = vec->bands[flags.band];
	return *(tvalue *) (((char *) band) + (flags.stride * idx + flags.offset));
}

__attribute__((no_sanitize("alignment")))
static inline tvalue resv_grid(struct gv_grid *g, uint64_t f){
	FLAGS(g) flags = {.u64 = f};
	gridpos z = grid_zoom_up(*g->bind, GRID_POSITION_ORDER, g->grid->order);
	return *(tvalue *) (((char *) grid_data(g->grid, z)) + flags.offset);
}

__attribute__((no_sanitize("alignment")))
static inline tvalue resv_data(struct gv_data *d){
	return *(tvalue *) d->ref;
}

static int G_fail_exec(struct fhk_graph *G, void *udata, pvalue *ret, pvalue *args){
	(void)G;
	(void)udata;
	(void)ret;
	(void)args;

	assert(IS_MAINGRAPH(G));
	dv("Trying execute model from main graph, this should never happen\n");
	return -1;
}

static int G_fail_resolve(struct fhk_graph *G, void *udata, pvalue *value){
	(void)G;
	(void)udata;
	(void)value;

	assert(IS_MAINGRAPH(G));
	dv("Trying to resolve var from main graph, use a subgraph instead\n");
	return -1;
}

#define NAME(x) ((x) ? (x)->name : "(unmapped)")

static const char *G_ddv(void *udata){
	return NAME((struct gv_any *) udata);
}

static const char *G_ddm(void *udata){
	return NAME((struct gmap_model *) udata);
}

#ifdef DEBUG

static void debug_var_bind(struct fhk_graph *G, unsigned idx, struct gv_any *g){
	char buf[1024];

	switch(g->flags.rtype){
		case GMAP_VEC: {
			struct gv_vec *v = (struct gv_vec *) g;
			snprintf(buf, sizeof(buf), "vec<bind=%p> band[%u][*%p]*%u+%u",
					v->v_bind,
					v->flags.band,
					v->idx_bind,
					v->flags.stride,
					v->flags.offset
			);
		}
		break;

		case GMAP_ENV: {
			struct gv_grid *v = (struct gv_grid *) g;
			snprintf(buf, sizeof(buf), "grid<%p, z=%p> +%u",
					v->grid,
					v->bind,
					v->flags.offset
			);
		}
		break;

		case GMAP_DATA: {
			struct gv_data *v = (struct gv_data *) g;
			snprintf(buf, sizeof(buf), "ptr<%p>", v->ref);
		}
		break;

		case GMAP_INTERRUPT: {
			struct gv_int *v = (struct gv_int *) g;
			snprintf(buf, sizeof(buf), "interrupt#%d", v->flags.handle);
		}
		break;

		case GMAP_COMPUTED:
			return; // not bound to anything, don't log these

		default: UNREACHABLE();
	}

	dv("%smap %s type=%u.%u : %s -> fhk var[%u]\n",
			G->vars[idx].udata ? "(!) re" : "",
			g->name,
			TYPE_BASE(g->flags.vtype),
			TYPE_SIZE(g->flags.vtype),
			buf,
			idx
	);
}

#endif
