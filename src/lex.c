#include "def.h"
#include "lex.h"

#include <stdlib.h>

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

const struct type_def *get_typedef(enum type idx){
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

enum type get_enum_type(struct bitenum_def *ed){
	switch(get_enum_size(ed->bit_mask)){
		case 1: return T_B8;
		case 2: return T_B16;
		case 4: return T_B32;
		case 8: return T_B64;
	}

	UNREACHABLE();
}

enum ptype get_ptype(enum type type){
	switch(type){
		case T_F32:
		case T_F64:
			return T_REAL;

		case T_I8:
		case T_I16:
		case T_I32:
		case T_I64:
			return T_INT;

		case T_B8:
		case T_B16:
		case T_B32:
		case T_B64:
			return T_BIT;
	}

	UNREACHABLE();
}

int get_enum_bit(uint64_t bit){
	assert(bit > 0);
	return __builtin_ctzl(bit);
}

uint64_t get_bit_enum(int bit){
	assert(bit >= 0 && bit < 64);
	return 1ULL << bit;
}
