#pragma once

#include <stdlib.h>
#include <stdint.h>
#include <assert.h>

#include "def.h"
#include "list.h"
#include "grid.h"

// XXX should types,ptypes,pvalues,tvecs etc. go into "type.h"/"typing.h"?

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
	T_B64      = 9,

	// TODO: is a complex type needed?
	
	T_POSITION = 10,
	T_USERDATA = 11
} type;

/* promoted types, mostly used with fhk */
typedef enum ptype {
	PT_REAL    = 1, // F*
	PT_INT     = 2, // I*
	PT_BIT     = 3, // B*
	PT_POS     = 4, // POSITION
	PT_UDATA   = 5  // USERDATA
} ptype;

/* promoted values */
typedef union pvalue {
	double r;   // F*
	int64_t i;  // I*
	uint64_t b; // B*
	gridpos p;  // POSITION
	void *u;    // USERDATA
} pvalue;

/* don't put anything dumb there so it fits in a register */
static_assert(sizeof(pvalue) == sizeof(uint64_t));

/* typed vector */
struct tvec {
	type type;
	size_t stride;
	void *data;
};

/* builtin vars, created automatically for each object */
enum {
	VARID_POSITION = 0
};

#define POSITION_RESOLUTION 31
#define POSITION_ORDER      GRID_ORDER(POSITION_RESOLUTION)

typedef unsigned lexid;

struct var_def {
	lexid id;
	const char *name;
	type type;
	// unit ?
};

struct obj_def {
	lexid id;
	const char *name;
	size_t resolution;
	VEC(struct var_def) vars;
};

struct env_def {
	lexid id;
	const char *name;
	size_t resolution;
	type type;
};

struct lex {
	VEC(struct obj_def) objs;
	VEC(struct env_def) envs;
};

struct lex *lex_create();
void lex_destroy(struct lex *lex);

struct obj_def *lex_add_obj(struct lex *lex);
struct env_def *lex_add_env(struct lex *lex);
struct var_def *lex_add_var(struct obj_def *obj);

int unpackenum(uint64_t b);
uint64_t packenum(int b);

size_t tsize(type t);
ptype tpromote(type t);
pvalue promote(void *x, type t);
void demote(void *x, type t, pvalue p);

void tvec_init(struct tvec *v, type t);
void *tvec_varp(struct tvec *v, size_t p);
