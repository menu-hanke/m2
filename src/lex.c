#include "lex.h"

#include <stdlib.h>

const struct type_def *get_typedef(type idx){
#define TD(t,n,s) [t]={.name=(n), .size=(s)}
	static const struct type_def typedefs[] = {
		TD(T_F32, "f32", 4),
		TD(T_F64, "f64", 8),
		TD(T_I8,  "i8",  1),
		TD(T_I16, "i16", 2),
		TD(T_I32, "i32", 4),
		TD(T_I64, "i64", 8),
		TD(T_B8,  "b8",  1),
		TD(T_B16, "b16", 2),
		TD(T_B32, "b32", 4),
		TD(T_B64, "b64", 8)
	};
#undef TD

	return &typedefs[idx];
}

size_t get_enum_size(uint64_t bit_mask){
	if(!(bit_mask & ~0xff))
		return 1;
	if(!(bit_mask & ~0xffff))
		return 2;
	if(!(bit_mask & ~0xffffffff))
		return 4;
	return 8;
}

type get_enum_type(struct bitenum_def *ed){
	switch(get_enum_size(ed->bit_mask)){
		case 1: return T_B8;
		case 2: return T_B16;
		case 4: return T_B32;
		case 8: return T_B64;
	}

	UNREACHABLE();
}

int unpackenum(uint64_t bit){
	assert(bit > 0);
	return __builtin_ctzl(bit);
}

uint64_t packenum(int bit){
	assert(bit >= 0 && bit < 64);
	return 1ULL << bit;
}

ptype tpromote(type t){
	switch(t){
		case T_F32:
		case T_F64:
			return PT_REAL;

		case T_I8:
		case T_I16:
		case T_I32:
		case T_I64:
			return PT_INT;

		case T_B8:
		case T_B16:
		case T_B32:
		case T_B64:
			return PT_BIT;
	}

	UNREACHABLE();
}

pvalue promote(void *x, type t){
	pvalue ret;

	switch(t){
		case T_F32: ret.r = *((float *) x); break;
		case T_F64: ret.r = *((double *) x); break;
		case T_I8:  ret.i = *((int8_t *) x); break;
		case T_I16: ret.i = *((int16_t *) x); break;
		case T_I32: ret.i = *((int32_t *) x); break;
		case T_I64: ret.i = *((int64_t *) x); break;
		case T_B8:  ret.b = *((uint8_t *) x); break;
		case T_B16: ret.b = *((uint16_t *) x); break;
		case T_B32: ret.b = *((uint32_t *) x); break;
		case T_B64: ret.b = *((uint64_t *) x); break;
		default: UNREACHABLE();
	}

	return ret;
}

void demote(void *x, type t, pvalue p){
	switch(t){
		case T_F32: *((float *) x) = p.r; break;
		case T_F64: *((double *) x) = p.r; break;
		case T_I8:  *((int8_t *) x) = p.i; break;
		case T_I16: *((int16_t *) x) = p.i; break;
		case T_I32: *((int32_t *) x) = p.i; break;
		case T_I64: *((int64_t *) x) = p.i; break;
		case T_B8:  *((uint8_t *) x) = p.b; break;
		case T_B16: *((uint16_t *) x) = p.b; break;
		case T_B32: *((uint32_t *) x) = p.b; break;
		case T_B64: *((uint64_t *) x) = p.b; break;
		default: UNREACHABLE();
	}
}
}
