#pragma once

#include "bitmap.h"
#include "arena.h"
#include "lex.h" /* for pvalue */

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
	/* model info */
	unsigned idx;
	double k, c;
	size_t n_check;
	struct fhk_check *checks;
	size_t n_param;
	struct fhk_var **params;
	pvalue *returns;

	/* used by solver */
	double min_cost, max_cost;

	/* user data */
	void *udata;
};

struct fhk_var {
	/* var info */
	unsigned idx;
	size_t n_mod;
	struct fhk_model **models;
	pvalue **mret;

	/* used by solver */
	pvalue value;
	unsigned select_model;
	double min_cost, max_cost;

	/* user data */
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
 * may_fail       : (e)  is this model allowed to fail, ie. return a status other than FHK_OK? */
typedef union fhk_mbmap BMU8({
	unsigned blacklisted : 1;     // 1
	unsigned has_bound : 1;       // 2
	unsigned chain_selected : 1;  // 3
	unsigned has_return : 1;      // 4
	unsigned may_fail : 1;        // 5
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
 * solve          : (e)  does this variable have to be solved?
 * solving        : (i)  is the solver currently inside this variable's chain?
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
 */
typedef union fhk_vbmap BMU8({
	unsigned given : 1;           // 1
	unsigned solve : 1;           // 2
	unsigned solving : 1;         // 3
	unsigned chain_selected : 1;  // 4
	unsigned has_value : 1;       // 5
	unsigned has_bound : 1;       // 6
	unsigned stable : 1;          // 7
}) fhk_vbmap;

enum {
	FHK_NOT_RESOLVED = -1,
	FHK_OK = 0,
	FHK_RESOLVE_FAILED = 1,
	FHK_MODEL_FAILED = 2,
	FHK_CYCLE = 3,
	FHK_REQUIRED_UNSOLVABLE = 4
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

	struct fhk_einfo last_error;
	void *udata;
};

/* fhk_graph.c */
void fhk_reset(struct fhk_graph *G, fhk_vbmap vmask, fhk_mbmap mmask);
void fhk_supp(bm8 *vmask, bm8 *mmask, struct fhk_var *y);
// TODO: now that we have a full list of variables inv_supp doesn't need to take root
void fhk_inv_supp(struct fhk_graph *G, bm8 *vmask, bm8 *mmask, struct fhk_var *y);
// TODO: space intersection stuff..

/* fhk_solve.c */
int fhk_solve(struct fhk_graph *G, struct fhk_var *y);

/* fhk_aux.c */
struct fhk_graph *fhk_alloc_graph(arena *arena, size_t n_var, size_t n_mod);
void fhk_alloc_checks(arena *arena, struct fhk_model *m, size_t n_check, struct fhk_check *checks);
void fhk_alloc_params(arena *arena, struct fhk_model *m, size_t n_param, struct fhk_var **params);
void fhk_alloc_returns(arena *arena, struct fhk_model *m, size_t n_ret);
void fhk_alloc_models(arena *arena, struct fhk_var *x, size_t n_mod, struct fhk_model **models);
void fhk_link_ret(struct fhk_model *m, struct fhk_var *x, size_t mind, size_t xind);
struct fhk_var *fhk_get_var(struct fhk_graph *G, unsigned idx);
struct fhk_model *fhk_get_model(struct fhk_graph *G, unsigned idx);
struct fhk_model *fhk_get_select(struct fhk_var *x);
