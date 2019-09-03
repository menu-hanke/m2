#pragma once

/* The "type" enum, unsurprisingly, represents C datatypes with some useful aliases.
 * These data type conversions are needed so we can automatically convert & pass correctly
 * typed values to outside of simulator (e.g. fhk and external models).
 * fhk uses double/bitenum for constraint checking. Usually external models take only
 * doubles, so we must be able to figure out how to convert data.
 * The other alternative would be to store everything as double (like, for example SIMO does),
 * but we prefer the benefit of smaller vectors
 *
 * Type enum values:
 *     - 2 low bits indicate type size: sz = 1 << (type & 0b11)
 *     - High bits indicate the "kind" (real, integer, bit-enum)
 *     - To promote a type, mask out the 2 low bits
 * */

#include "grid.h"

#include <stdint.h>
#include <assert.h>

#define TS(n)            ((!!((n)&0xa)) | ((!!((n)&0xc))<<1))
#define TYPE(base, size) (((base) << 2) | TS(size))
#define TYPE_SIZE(t)     ((unsigned) (1 << ((t) & 3)))
#define TYPE_BASE(t)     ((t) >> 2)
#define TYPE_PROMOTE(t)  ((t) | 3)
#define TYPE_IS_REAL(t)  (!((t)&~3))

typedef enum type {
	T_F64      = TYPE(0, 8),
	T_F32      = TYPE(0, 4),
	T_B64      = TYPE(1, 8),
	T_B32      = TYPE(1, 4),
	T_B16      = TYPE(1, 2),
	T_B8       = TYPE(1, 1),
	T_BOOL64   = TYPE(2, 8),
	T_BOOL8    = TYPE(2, 1),
	T_U64      = TYPE(3, 8),
	T_U32      = TYPE(3, 4),
	T_U16      = TYPE(3, 2),
	T_U8       = TYPE(3, 1),

	// aliases
	T_ID       = T_U64,
	T_POSITION = T_U64 | TS(sizeof(gridpos)),
	T_USERDATA = T_U64 | TS(sizeof(void *))
} type;

#define PVALUE    \
	double   f64; \
	uint64_t u64; \
	gridpos  z;   \
	void    *u

typedef union pvalue {
	PVALUE;
} pvalue;

typedef union tvalue {
	PVALUE;
	float    f32;
	uint8_t  u8;
	uint16_t u16;
	uint32_t u32;
} tvalue;

/* don't put anything dumb there so it fits in a register */
static_assert(sizeof(tvalue) == sizeof(uint64_t));
static_assert(sizeof(pvalue) == sizeof(uint64_t));

pvalue vpromote(tvalue v, type t);
tvalue vdemote(pvalue v, type t);
tvalue vbroadcast(tvalue v, type t);
unsigned vbunpack(uint64_t b);
uint64_t vbpack(unsigned b);
double vexportd(pvalue v, type t);
pvalue vimportd(double d, type t);
