#include "lex.h"
#include "list.h"

#include <stdlib.h>
#include <stdint.h>
#include <string.h>

static void create_builtins(struct obj_def *obj);

struct lex *lex_create(){
	struct lex *lex = malloc(sizeof(*lex));
	VEC_INIT(lex->objs, 32);
	VEC_INIT(lex->envs, 32);
	return lex;
}

void lex_destroy(struct lex *lex){
	for(size_t i=0;i<VECN(lex->objs);i++){
		struct obj_def *obj = &VECE(lex->objs, i);
		VEC_FREE(obj->vars);
	}

	VEC_FREE(lex->objs);
	VEC_FREE(lex->envs);
	free(lex);
}

struct obj_def *lex_add_obj(struct lex *lex){
	struct obj_def *obj = VEC_ADD(lex->objs);
	obj->id = VECN(lex->objs) - 1;
	obj->name = NULL;
	VEC_INIT(obj->vars, 16);
	create_builtins(obj);
	return obj;
}

struct env_def *lex_add_env(struct lex *lex){
	struct env_def *env = VEC_ADD(lex->envs);
	env->id = VECN(lex->envs) - 1;
	env->name = NULL;
	return env;
}

struct var_def *lex_add_var(struct obj_def *obj){
	struct var_def *var = VEC_ADD(obj->vars);
	var->id = VECN(obj->vars) - 1;
	var->name = NULL;
	return var;
}

int unpackenum(uint64_t bit){
	assert(bit > 0);
	return __builtin_ctzl(bit);
}

uint64_t packenum(int bit){
	assert(bit >= 0 && bit < 64);
	return 1ULL << bit;
}

type tfitenum(unsigned max){
	if(max < 8)
		return T_B8;
	if(max < 16)
		return T_B16;
	if(max < 32)
		return T_B32;
	if(max < 64)
		return T_B64;

	assert(0);
	return T_B64;
}

size_t tsize(type t){
	static const uint8_t sizes[] = {
		[T_F32]      = 4,
		[T_F64]      = 8,
		[T_B8]       = 1,
		[T_B16]      = 2,
		[T_B32]      = 4,
		[T_B64]      = 8,
		[T_BOOL]     = 1,
		[T_POSITION] = sizeof(gridpos),
		[T_USERDATA] = sizeof(void *)
	};

	return sizes[t];
}

ptype tpromote(type t){
	switch(t){
		case T_F32:
		case T_F64:
			return PT_REAL;

		case T_B8:
		case T_B16:
		case T_B32:
		case T_B64:
			return PT_BIT;

		case T_BOOL:
			return PT_BOOL;

		case T_ID:
			return PT_ID;

		case T_POSITION:
			return PT_POS;

		case T_USERDATA:
			return PT_UDATA;
	}

	UNREACHABLE();
}

pvalue vpromote(tvalue v, type t){
	pvalue ret;

	switch(t){
		case T_F32:      ret.r = v.f32; break;
		case T_F64:      ret.r = v.f64; break;
		case T_B8:       ret.b = v.b8; break;
		case T_B16:      ret.b = v.b16; break;
		case T_B32:      ret.b = v.b32; break;
		case T_B64:      ret.b = v.b64; break;
		case T_BOOL:     ret.b = v.b; break;
		case T_ID:       ret.id = v.id; break;
		case T_POSITION: ret.z = v.z; break;
		case T_USERDATA: ret.u = v.u; break;
		default: UNREACHABLE();
	}

	return ret;
}

tvalue vdemote(pvalue v, type t){
	tvalue ret;

	switch(t){
		case T_F32:      ret.f32 = v.r; break;
		case T_F64:      ret.f64 = v.r; break;
		case T_B8:       ret.b8  = v.b; break;
		case T_B16:      ret.b16 = v.b; break;
		case T_B32:      ret.b32 = v.b; break;
		case T_B64:      ret.b64 = v.b; break;
		case T_BOOL:     ret.b   = v.b; break;
		case T_ID:       ret.id  = v.id; break;
		case T_POSITION: ret.z   = v.z; break;
		case T_USERDATA: ret.u   = v.u; break;
		default: UNREACHABLE();
	}

	return ret;
}

tvalue vbroadcast(tvalue v, type t){
	tvalue ret;
	ret.b64 = broadcast64(v.b64, tsize(t));
	return ret;
}

uint64_t broadcast64(uint64_t x, unsigned b){
	assert(b == 1 || b == 2 || b == 4 || b == 8);

	if(b <= 1)
		x = (x & 0xff) | (x << 8);
	if(b <= 2)
		x = (x & 0xffff) | (x << 16);
	if(b <= 4)
		x = (x & 0xffffffff) | (x << 32);

	return x;
}

static void create_builtins(struct obj_def *obj){
	struct var_def *pos = lex_add_var(obj);
	pos->name = "builtin$pos";
	pos->type = T_POSITION;
}
