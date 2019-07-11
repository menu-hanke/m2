#pragma once

#include <stdlib.h>
#include <stdint.h>
#include <assert.h>

#include "def.h"

enum type {
	/* reals */
	T_F32      = 1,
	T_F64      = 2,

	/* integers */
	T_I8       = 3,
	T_I16      = 4,
	T_I32      = 5,
	T_I64      = 6,

	// TODO: is a complex type needed?

	/* bit-enums, implemented as a mask */
	T_B8       = 7,
	T_B16      = 8,
	T_B32      = 9,
	T_B64      = 10,

	// TODO: simd bit vector types
	/*
	T_B128     = 11,
	T_B256     = 12,
	*/

	/* TODO: hash enum, implemented as a hash set */
	/*
	T_HENUM    = 13
	*/
};

/* promoted types, mostly used with fhk */
enum ptype {
	T_REAL    = 1, // F*
	T_INT     = 2, // I*
	T_BIT     = 3  // B*
};

/* promoted values */
union pvalue {
	double r;   // F*
	int64_t i;  // I*
	uint64_t b; // B*
	void *p;    // other stuff
};

/* don't put anything dumb there so it fits in a register */
static_assert(sizeof(union pvalue) == sizeof(uint64_t));

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
	enum type type;

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

const struct type_def *get_typedef(enum type type);
size_t get_enum_size(uint64_t bit_mask);
enum type get_enum_type(struct bitenum_def *ed);
enum ptype get_ptype(enum type type);
int get_enum_bit(uint64_t bit);
uint64_t get_bit_enum(int bit);
