#pragma once

#include "bitmap.h"
#include "arena.h"
#include "type.h"

#include <stdint.h>
#include <stddef.h>
#include <assert.h>

enum fhk_ctype {
	FHK_RIVAL,
	FHK_BITSET
};

struct fhk_rival {
	double min;
	double max;
};

struct fhk_cst {
	enum fhk_ctype type;
	union {
		struct fhk_rival rival;
		uint64_t setmask;
	};
};

// TODO: space intersection stuff
struct fhk_space {
	struct fhk_cst cst; // ?
};

enum {
	FHK_COST_OUT = 0,
	FHK_COST_IN = 1
};

struct fhk_check {
	struct fhk_var *var;
	struct fhk_cst cst;
	double costs[2];
};

struct fhk_model {
	unsigned idx : 16;
	unsigned n_check : 8;
	unsigned n_param : 8;
	unsigned n_return : 8;
	unsigned may_fail : 1;
	struct fhk_check *checks;
	struct fhk_var **params;
	struct fhk_var **returns;
	pvalue *rvals;
	double k, c;
	double min_cost, max_cost;
	void *udata;
};

struct fhk_var {
	unsigned idx : 16;
	unsigned n_fwd : 16;
	unsigned n_mod : 8;
	unsigned hptr : 8;
	struct fhk_model **models;
	struct fhk_model **fwd_models;
	struct fhk_model *model;
	pvalue value;
	double min_cost, max_cost;
	void *udata;
};

/* (i)  : internal flag, the solver will set this, reset to 0
 * (e)  : external flag, you may set this
 * (ie) : internal/external, the solver will change this but you may set a default */

/* blacklisted    : (ie) skip this model? when a model returns with an error,
 *                       the solver blacklists the model and tries another chain.
 * has_bound      : (i)  has ANY cost bound been found?
 * chain_selected : (i)  has a chain been selected for this model?
 * has_return     : (i)  has this model been run succesfully and returned its return values?
 * mark           : (i)  coloring used by solver
 */
typedef union fhk_mbmap BMU8({
	unsigned blacklisted : 1;     // 1
	unsigned has_bound : 1;       // 2
	unsigned chain_selected : 1;  // 3
	unsigned has_return : 1;      // 4
	unsigned mark : 1;            // 5
}) fhk_mbmap;

/* given          : (ie) is a value given for this variable? if this flag is set, the solver
 *                       will not search up from this variable, and its cost will be treated
 *                       as 0.
 *                       if stable=0 then the solver will set this flag depending on the
 *                       return value of var_resolve().
 *                       if stable=1,given=1 then the solver may call var_resolve() depending
 *                       on the has_value flag
 *                       if stable=1,given=0 then the solver will attempt to find a chain for
 *                       this variable and it will never call var_resolve() on it
 * mark           : (i)  coloring used by solver
 * chain_selected : (i)  has a chain been selected for this variable? 
 * has_value      : (ie) does this variable have a solved or given value?
 *                       if stable=0 then the solver will call var_resolve() on this variable when
 *                       determining cost bounds and set has_value if it returns FHK_OK.
 *                       if stable=1,given=1 and has_value=0 then the solver will call var_resolve()
 *                       lazily when it needs the value, ie. as a constraint, call parameter
 *                       or if solve=1
 *                       if stable=1,given=1,has_value=1 then the solver will use the value
 *                       in struct fhk_var and never call var_resolve() on this
 * has_bound      : (i)  has ANY cost bound been found?
 * stable         : (ie) should the solver trust the given and has_value flags? (see their comments)
 * target         : (i)  does this need to be solved? (don't set this, used internally by dijkstra
 *                       solver)
 */
typedef union fhk_vbmap BMU8({
	unsigned given : 1;           // 1
	unsigned mark : 1;            // 2
	unsigned chain_selected : 1;  // 3
	unsigned has_value : 1;       // 4
	unsigned has_bound : 1;       // 5
	unsigned stable : 1;          // 6
	unsigned target : 1;          // 7
}) fhk_vbmap;

enum {
	FHK_NOT_RESOLVED = -1,
	FHK_OK = 0,
	FHK_RESOLVE_FAILED = 1,
	FHK_MODEL_FAILED = 2,
	FHK_SOLVER_FAILED = 3
};

struct fhk_einfo {
	int err;
	struct fhk_model *model;
	struct fhk_var *var;
};

typedef struct fhk_graph fhk_graph;

typedef int (*fhk_model_exec)(fhk_graph *G, void *udata, pvalue *ret, pvalue *args);
typedef int (*fhk_var_resolve)(fhk_graph *G, void *udata, pvalue *value);
typedef void (*fhk_chain_solved)(fhk_graph *G, void *udata, pvalue value);
typedef const char *(*fhk_desc)(void *udata);

struct fhk_graph {
	fhk_model_exec exec_model;
	fhk_var_resolve resolve_var;
	fhk_chain_solved chain_solved;
	fhk_desc debug_desc_var;
	fhk_desc debug_desc_model;

	size_t n_var;
	struct fhk_var *vars;
	fhk_vbmap *v_bitmaps;

	size_t n_mod;
	struct fhk_model *models;
	fhk_mbmap *m_bitmaps;

	unsigned dirty;
	struct fhk_einfo last_error;
	void *udata;
};

struct fhk_solver {
	struct fhk_graph *G;
	bm8 *reset_v;
	bm8 *reset_m;
	unsigned nv;
	struct fhk_var **xs;
	pvalue **res;
};

/* fhk_graph.c */
void fhk_reset(struct fhk_graph *G, fhk_vbmap vmask, fhk_mbmap mmask);
void fhk_reset_mask(struct fhk_graph *G, bm8 *vmask, bm8 *mmask);
void fhk_supp(bm8 *vmask, bm8 *mmask, struct fhk_var *y);
void fhk_inv_supp(struct fhk_graph *G, bm8 *vmask, bm8 *mmask);

/* fhk_solve.c */
int fhk_solve(struct fhk_graph *G, size_t nv, struct fhk_var **ys);

/* fhk_aux.c */
struct fhk_graph *fhk_alloc_graph(arena *arena, size_t n_var, size_t n_mod);
void fhk_copy_checks(arena *arena, struct fhk_model *m, size_t n_check, struct fhk_check *checks);
void fhk_copy_params(arena *arena, struct fhk_model *m, size_t n_param, struct fhk_var **params);
void fhk_copy_returns(arena *arena, struct fhk_model *m, size_t n_ret, struct fhk_var **returns);
void fhk_compute_links(arena *arena, struct fhk_graph *G);
struct fhk_var *fhk_get_var(struct fhk_graph *G, unsigned idx);
struct fhk_model *fhk_get_model(struct fhk_graph *G, unsigned idx);
void fhk_solver_init(struct fhk_solver *s, struct fhk_graph *G, unsigned nv);
void fhk_solver_destroy(struct fhk_solver *s);
void fhk_solver_bind(struct fhk_solver *s, unsigned vidx, pvalue *res);
int fhk_solver_step(struct fhk_solver *s, unsigned idx);
