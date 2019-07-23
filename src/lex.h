#pragma once

#include <stdlib.h>
#include <stdint.h>
#include <assert.h>

#include "def.h"

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
	const char *name;
	type type;

	/* if type is T_B* then this has the details of the enum */
	union {
		struct bitenum_def *bitenum_def; // T_B*
		// struct hashenum_def *hashenum_def // T_HENUM
		// struct unit_def *unit_def; // T_I*, T_F*
	};
};

struct obj_def {
	const char *name;
	size_t n_var;
	struct var_def **vars;
	struct obj_def *owner;
};

/* struct invariant {...} goes here */

const struct type_def *get_typedef(type t);
size_t get_enum_size(uint64_t bit_mask);
type get_enum_type(struct bitenum_def *ed);

int unpackenum(uint64_t b);
uint64_t packenum(int b);

ptype tpromote(type t);
pvalue promote(void *x, type t);
void demote(void *x, type t, pvalue p);
