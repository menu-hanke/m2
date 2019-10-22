#include "type.h"
#include "def.h"

#include <stdint.h>
#include <assert.h>

/* XXX: vpromote and vdemote currently assume little-endian, should also make big-endian versions */

pvalue vpromote(tvalue v, type t){
	if(UNLIKELY(!TYPE_IS_PTYPE(t))){
		if(TYPE_IS_REAL(t)){
			v.f64 = v.f32;
		}else{
			uint64_t mask = (1ULL << (8 * TYPE_SIZE(t))) - 1;
			v.u64 &= mask;
		}
	}

	return (pvalue) v.u64;
}

tvalue vdemote(pvalue v, type t){
	tvalue ret = (tvalue) v.u64;

	if(UNLIKELY(t == T_F32))
		ret.f32 = ret.f64;

	return ret;
}

tvalue vbroadcast(tvalue v, type t){
	uint64_t x = v.u64;
	unsigned s = t & 3;
	if(s <= 0) x = (x & 0xff)       | (x << 8);
	if(s <= 1) x = (x & 0xffff)     | (x << 16);
	if(s <= 2) x = (x & 0xffffffff) | (x << 32);
	v.u64 = x;

	return v;
}

unsigned vbunpack(uint64_t b){
	assert(b > 0);
	return __builtin_ctzl(b);
}

uint64_t vbpack(unsigned b){
	assert(b < 64);
	return 1ULL << b;
}

double vexportd(pvalue v, type t){
	switch(t){
		case T_F64:    return v.f64;
		case T_B64:    return (double) vbunpack(v.u64);
		case T_BOOL64: return (double) !!v.u64;
		case T_U64:    return (double) v.u64;
		default:       UNREACHABLE();
	}
}

pvalue vimportd(double d, type t){
	switch(t){
		case T_F64:    return (pvalue) d;
		case T_B64:    return (pvalue) vbpack((uint64_t) d);
		case T_BOOL64: /* fallthrough */
		case T_U64:    return (pvalue) (uint64_t) d;
		default:       UNREACHABLE();
	}
}
