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

size_t tsize(type t){
	static const uint8_t sizes[] = {
		[T_F32] = 4,
		[T_F64] = 8,
		[T_B8]  = 1,
		[T_B16] = 2,
		[T_B32] = 4,
		[T_B64] = 8,
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

		case T_POSITION:
			return PT_POS;

		case T_USERDATA:
			return PT_UDATA;
	}

	UNREACHABLE();
}

pvalue promote(void *x, type t){
	pvalue ret;

	switch(t){
		case T_F32:      ret.r = *((float *)    x); break;
		case T_F64:      ret.r = *((double *)   x); break;
		case T_B8:       ret.b = *((uint8_t *)  x); break;
		case T_B16:      ret.b = *((uint16_t *) x); break;
		case T_B32:      ret.b = *((uint32_t *) x); break;
		case T_B64:      ret.b = *((uint64_t *) x); break;
		case T_POSITION: ret.p = *((gridpos *)  x); break;
		case T_USERDATA: ret.u = *((void **)    x); break;
		default: UNREACHABLE();
	}

	return ret;
}

void demote(void *x, type t, pvalue p){
	switch(t){
		case T_F32:      *((float *)    x) = p.r; break;
		case T_F64:      *((double *)   x) = p.r; break;
		case T_B8:       *((uint8_t *)  x) = p.b; break;
		case T_B16:      *((uint16_t *) x) = p.b; break;
		case T_B32:      *((uint32_t *) x) = p.b; break;
		case T_B64:      *((uint64_t *) x) = p.b; break;
		case T_POSITION: *((gridpos *)  x) = p.p; break;
		case T_USERDATA: *((void **)    x) = p.u; break;
		default: UNREACHABLE();
	}
}

static void create_builtins(struct obj_def *obj){
	struct var_def *pos = lex_add_var(obj);
	pos->name = "builtin$pos";
	pos->type = T_POSITION;
}
