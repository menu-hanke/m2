#pragma once

#include "bitmap.h"
#include "lex.h" /* for pvalue */

#include <stdint.h>
#include <stddef.h>
#include <assert.h>

enum fhk_ctype {
	FHK_RIVAL,
	FHK_IIVAL,
	FHK_BITSET
};

struct fhk_rival {
	double min;
	double max;
};

struct fhk_iival {
	int64_t min;
	int64_t max;
};

struct fhk_cst {
	enum fhk_ctype type;
	union {
		struct fhk_rival rival;
		struct fhk_iival iival;
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

struct fhk_mmark {
	double min_cost, max_cost;
};

struct fhk_vmark {
	union {
		/* regular solver */
		struct {
			pvalue value;
			//int model; //?
			struct fhk_model *model;
			double min_cost, max_cost;
		};

		/* graph pruning */
		struct {
			struct fhk_space space;
			unsigned limit_space : 1;
			unsigned given : 1;
		};
	};
};

struct fhk_model {
	/* model info */
	int idx;
	double k, c;
	size_t n_check;
	struct fhk_check *checks;
	// XXX: params (also var models) could be just an index list since most accesses
	// are on bitmaps anyway
	size_t n_param;
	struct fhk_var **params;
	// TODO: either here on in struct fhk_graph should be a place
	// to store multi return values
	unsigned may_fail : 1;

	/* used by solver */
	struct fhk_mmark mark;

	/* user data */
	void *udata;
};

struct fhk_var {
	/* var info */
	int idx;
	size_t n_mod;
	struct fhk_model **models;

	// virtual given variables have their value resolved by a function,
	// the resolution logic assuming given=1 goes
	// is_virtual=1
	//     has_value=1 -> use stored value
	//     has_value=0 -> resolve
	// is_virtual=0 -> use stored value regardless of has_value.
	// this is so that values can be resetted simply by setting has_value=0
	// for the whole bitmap array
	unsigned is_virtual : 1;

	/* used by solver */
	struct fhk_vmark mark;

	/* user data */
	void *udata;
};

typedef union fhk_mbmap BMU8({
	unsigned skip : 1;            // 1
	unsigned has_bound : 1;       // 2
	unsigned chain_selected : 1;  // 3
}) fhk_mbmap;

typedef union fhk_vbmap BMU8({
	unsigned given : 1;           // 1
	unsigned solve : 1;           // 2
	unsigned solving : 1;         // 3
	unsigned chain_selected : 1;  // 4
	unsigned has_value : 1;       // 5
	unsigned has_bound : 1;       // 6
}) fhk_vbmap;

enum {
	FHK_RESET_GIVEN = 0x1,
	FHK_RESET_SOLVE = 0x2,
	FHK_RESET_ALL = FHK_RESET_GIVEN | FHK_RESET_SOLVE
};

enum {
	FHK_OK = 0,
	FHK_MODEL_FAILED = 1,
	FHK_RESOLVE_FAILED = 2,
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
typedef const char *(*fhk_desc)(void *udata);

struct fhk_graph {
	fhk_model_exec model_exec;
	fhk_var_resolve resolve_virtual;
	fhk_desc debug_desc_var;
	fhk_desc debug_desc_model;

	size_t n_var;
	size_t n_mod;
	fhk_vbmap *v_bitmaps;
	fhk_mbmap *m_bitmaps;

	struct fhk_einfo last_error;
	void *udata;
};

/* fhk_graph.c */
void fhk_graph_init(struct fhk_graph *G);
void fhk_graph_destroy(struct fhk_graph *G);
void fhk_set_given(struct fhk_graph *G, struct fhk_var *x);
void fhk_set_solve(struct fhk_graph *G, struct fhk_var *y);
void fhk_reset(struct fhk_graph *G, int what);
void fhk_supp(bm8 *vmask, bm8 *mmask, struct fhk_var *y);
void fhk_inv_supp(struct fhk_graph *G, bm8 *vmask, bm8 *mmask, struct fhk_var *y);
// TODO: space intersection stuff..

/* fhk_solve.c */
int fhk_solve(struct fhk_graph *G, struct fhk_var *y);
