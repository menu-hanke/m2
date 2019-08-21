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

	/* bit-enums, implemented as a mask */
	T_B8       = 2,
	T_B16      = 3,
	T_B32      = 4,
	T_B64      = 5,

	T_BOOL     = 6,
	T_ID       = 7,

	// TODO: is a complex type needed?
	
	T_POSITION = 8,
	T_USERDATA = 9
} type;

typedef union tvalue {
	float    f32;
	double   f64;
	uint8_t  b8;
	uint16_t b16;
	uint32_t b32;
	uint64_t b64;
	uint8_t  b;
	uint32_t id;
	gridpos  z;
	void    *u;
} tvalue;

/* promoted types, mostly used with fhk */
typedef enum ptype {
	PT_REAL    = 1, // F*
	PT_BIT     = 2, // B*
	PT_BOOL    = 3, // BOOL
	PT_POS     = 4, // POSITION
	PT_ID      = 5, // ID
	PT_UDATA   = 6  // USERDATA
} ptype;

/* promoted values */
typedef union pvalue {
	double   r;   // F*
	uint64_t b;   // B* / BOOL
	uint64_t id;  // ID
	gridpos  z;   // POSITION
	void    *u;   // USERDATA
} pvalue;

/* don't put anything dumb there so it fits in a register */
static_assert(sizeof(tvalue) == sizeof(uint64_t));
static_assert(sizeof(pvalue) == sizeof(uint64_t));

enum {
	POSITION_RESOLUTION = 31,
	POSITION_ORDER      = GRID_ORDER(POSITION_RESOLUTION)
};

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

type tfitenum(unsigned max);
size_t tsize(type t);
ptype tpromote(type t);
pvalue vpromote(tvalue v, type t);
tvalue vdemote(pvalue v, type t);
void vcopy(void *dest, tvalue v, type t);
tvalue vbroadcast(tvalue v, type t);
uint64_t broadcast64(uint64_t x, unsigned b);
