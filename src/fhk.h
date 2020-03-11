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

typedef double fhk_v2 __attribute__((vector_size(16)));

struct fhk_check {
	struct fhk_var *var;
	struct fhk_cst cst;
	fhk_v2 cost; // {out, in}
};

/* (i)  : internal flag, the solver will set this, reset to 0
 * (e)  : external flag, you may set this
 * (ie) : internal/external, the solver will change this but you may set a default */

/* has_bound      : (i)  has ANY cost bound been found?
 * chain_selected : (i)  has a chain been selected for this model?
 * has_return     : (i)  has this model been run succesfully and returned its return values?
 * mark           : (i)  coloring used by solver
 */
typedef union fhk_mbmap BMU8({
	unsigned has_bound : 1;       // 1
	unsigned chain_selected : 1;  // 2
	unsigned has_return : 1;      // 3
	unsigned mark : 1;            // 4
}) fhk_mbmap;

/* given          : (e)  is this given? if set, the solver will not search a chain for this var
 * mark           : (i)  coloring used by solver
 * chain_selected : (i)  has a chain been selected for this variable? 
 * has_value      : (ie) does this variable have a solved or given value?
 * has_bound      : (i)  has ANY cost bound been found?
 * target         : (i)  does this need to be solved? internal flag of cyclic solver
 */
typedef union fhk_vbmap BMU8({
	unsigned given : 1;           // 1
	unsigned mark : 1;            // 2
	unsigned chain_selected : 1;  // 3
	unsigned has_value : 1;       // 4
	unsigned has_bound : 1;       // 5
	unsigned target : 1;          // 6
}) fhk_vbmap;

struct fhk_model {
	unsigned idx : 16;
	unsigned uidx : 16;         // index in original graph - not used by solver
	unsigned n_check : 8;
	unsigned n_param : 8;
	unsigned n_return : 8;
	fhk_mbmap *bitmap;
	struct fhk_check *checks;
	struct fhk_var **params;
	struct fhk_var **returns;
	fhk_v2 k, c;                // <- align
	fhk_v2 ki, ci;              // <- to
	fhk_v2 cost_bound;          // <- 16 bytes
	pvalue *rvals;
	void *udata;                // userdata - not used by solver
};

struct fhk_var {
	unsigned idx : 16;
	unsigned uidx : 16;         // index in original graph - not used by solver
	unsigned n_fwd : 16;
	unsigned n_mod : 8;
	unsigned hptr : 8;
	fhk_vbmap *bitmap;
	struct fhk_model **models;
	struct fhk_model **fwd_models;
	struct fhk_model *model;
	fhk_v2 cost_bound;          // <- align to 16 bytes
	pvalue value;
	void *udata;                // userdata - not used by solver
};

enum {
	FHK_OK            = 0,
	FHK_SOLVER_FAILED = 1,
	FHK_VAR_FAILED    = 2,
	FHK_MODEL_FAILED  = 3,
	FHK_RECURSION     = 4
};

struct fhk_einfo {
	int err;
	struct fhk_model *model;
	struct fhk_var *var;
};

struct fhk_graph;

typedef int (*fhk_model_exec)(struct fhk_graph *G, void *udata, pvalue *ret, pvalue *args);
typedef int (*fhk_var_resolve)(struct fhk_graph *G, void *udata, pvalue *value);
typedef const char *(*fhk_desc)(void *udata);

struct fhk_graph {
	fhk_model_exec exec_model;
	fhk_var_resolve resolve_var;
	fhk_desc debug_desc_var;
	fhk_desc debug_desc_model;

	size_t n_var;
	struct fhk_var *vars;
	fhk_vbmap *v_bitmaps;

	size_t n_mod;
	struct fhk_model *models;
	fhk_mbmap *m_bitmaps;

	struct fhk_einfo last_error;
	void *solver_state;

	void *udata;
};

/* fhk_graph.c */
void fhk_init(struct fhk_graph *G, bm8 *init_v);
void fhk_graph_init(struct fhk_graph *G);
void fhk_subgraph_init(struct fhk_graph *G);
void fhk_clear(struct fhk_graph *G);
void fhk_reset(struct fhk_graph *G, fhk_vbmap vmask, fhk_mbmap mmask);
void fhk_reset_mask(struct fhk_graph *G, bm8 *vmask, bm8 *mmask);
void fhk_compute_reset_mask(struct fhk_graph *G, bm8 *vmask, bm8 *mmask);
void fhk_inv_supp(struct fhk_graph *G, bm8 *vmask, bm8 *mmask);
size_t fhk_subgraph_size(struct fhk_graph *G, bm8 *vmask, bm8 *mmask);
void fhk_copy_subgraph(void *dest, struct fhk_graph *G, bm8 *vmask, bm8 *mmask);
void fhk_transfer_mask(bm8 *mH, bm8 *mG, bm8 *mask, size_t n);
void fhk_model_set_cost(struct fhk_model *m, double k, double c);
void fhk_check_set_cost(struct fhk_check *c, double out, double in);
double fhk_solved_cost(struct fhk_model *m);

/* fhk_solve.c */
int fhk_solve(struct fhk_graph *G, size_t nv, struct fhk_var **ys);
int fhk_reduce(struct fhk_graph *G, size_t nv, struct fhk_var **ys, bm8 *vmask, bm8 *mmask);

/* fhk_aux.c */
struct fhk_graph *fhk_alloc_graph(arena *arena, size_t n_var, size_t n_mod);
void fhk_copy_checks(arena *arena, struct fhk_model *m, size_t n_check, struct fhk_check *checks);
void fhk_copy_params(arena *arena, struct fhk_model *m, size_t n_param, struct fhk_var **params);
void fhk_copy_returns(arena *arena, struct fhk_model *m, size_t n_ret, struct fhk_var **returns);
void fhk_compute_links(arena *arena, struct fhk_graph *G);
