#pragma once

#include <stdlib.h>
#include <stdint.h>
#include <assert.h>

#include "def.h"
#include "list.h"

typedef enum type {
	/* reals */
	T_F32      = 0,
	T_F64      = 1,

	/* integers */
	T_I8       = 2,
	T_I16      = 3,
	T_I32      = 4,
	T_I64      = 5,

	/* bit-enums, implemented as a mask */
	T_B8       = 6,
	T_B16      = 7,
	T_B32      = 8,
	T_B64      = 9

	// TODO: is a complex type needed?
} type;

/* promoted types, mostly used with fhk */
typedef enum ptype {
	PT_REAL    = 1, // F*
	PT_INT     = 2, // I*
	PT_BIT     = 3  // B*
} ptype;

/* promoted values */
typedef union pvalue {
	double r;   // F*
	int64_t i;  // I*
	uint64_t b; // B*
} pvalue;

/* don't put anything dumb there so it fits in a register */
static_assert(sizeof(pvalue) == sizeof(uint64_t));

typedef unsigned lexid;

struct type_def {
	const char *name;
	size_t size;
};

struct bitenum_def {
	const char *name;
	uint64_t bit_mask;
	const char **value_names;
};

/* TODO. hash num def if needed */

struct var_def {
	lexid id;
	const char *name;
	type type;

	/* if type is T_B* then this has the details of the enum */
	union {
		struct bitenum_def *bitenum_def; // T_B*
		// struct hashenum_def *hashenum_def // T_HENUM
		// struct unit_def *unit_def; // T_I*, T_F*
	};
};

/* back_idx is the index of the corresponding backreference on the other obj_def:
 * if
 *     u = x->uprefs[i]
 *     d = x->downrefs[j]
 * then
 *     u->ref->downrefs[u->back_idx] == x
 *     d->ref->uprefs[d->back_idx] == x
 * 
 * back_idx is stored as index rather than pointer because some arrays (vector uprefs)
 * in the simulator are in the same order
 */
struct obj_ref {
	struct obj_def *ref;
	int back_idx;
};

struct obj_def {
	lexid id;
	const char *name;
	SVEC(struct var_def *) vars;
	SVEC(struct obj_ref) uprefs;
	SVEC(struct obj_ref) downrefs;
};

struct lex {
	SVEC(struct type_def) types;
	SVEC(struct var_def) vars;
	SVEC(struct obj_def) objs;
	// models go here? struct model_def?
};

/* struct invariant {...} goes here */

struct lex *lex_create(size_t n_types, size_t n_vars, size_t n_objs);
void lex_destroy(struct lex *lex);

void lex_set_vars(struct lex *lex, lexid objid, size_t n, lexid *varids);
void lex_set_uprefs(struct lex *lex, lexid objid, size_t n, lexid *objids);
void lex_compute_refs(struct lex *lex);
size_t lex_get_roots(struct lex *lex, struct obj_def **objs);

#define IS_ROOT(obj) (!((obj)->uprefs.n))

const struct type_def *get_typedef(type t);
size_t get_enum_size(uint64_t bit_mask);
type get_enum_type(struct bitenum_def *ed);

int unpackenum(uint64_t b);
uint64_t packenum(int b);

ptype tpromote(type t);
pvalue promote(void *x, type t);
void demote(void *x, type t, pvalue p);

// TODO void compute_backrefs(struct obj_def *objs, size_t n);
