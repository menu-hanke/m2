#include "lex.h"
#include "list.h"

#include <stdlib.h>
#include <stdint.h>
#include <string.h>

static void init_vardefs(struct lex *lex);
static void init_objdefs(struct lex *lex);
static void destroy_objdefs(struct lex *lex);
static void compute_downrefs(struct lex *lex);
static void compute_backrefs(struct lex *lex);

struct lex *lex_create(size_t n_types, size_t n_vars, size_t n_objs){
	struct lex *lex = calloc(1, sizeof *lex);

	SVEC_RESIZE(lex->types, n_types);
	SVEC_RESIZE(lex->vars, n_vars);
	SVEC_RESIZE(lex->objs, n_objs);

	memset(lex->types.data, 0, SVECSZ(lex->types));
	memset(lex->vars.data, 0, SVECSZ(lex->vars));
	memset(lex->objs.data, 0, SVECSZ(lex->objs));

	init_vardefs(lex);
	init_objdefs(lex);

	return lex;
}

void lex_destroy(struct lex *lex){
	destroy_objdefs(lex);
	free(lex->types.data);
	free(lex->vars.data);
	free(lex->objs.data);
	free(lex);
}

void lex_set_vars(struct lex *lex, lexid objid, size_t n, lexid *varids){
	struct obj_def *obj = &SVECE(lex->objs, objid);
	SVEC_RESIZE(obj->vars, n);
	for(size_t i=0;i<n;i++)
		obj->vars.data[i] = &SVECE(lex->vars, varids[i]);
}

void lex_set_uprefs(struct lex *lex, lexid objid, size_t n, lexid *objids){
	struct obj_def *obj = &SVECE(lex->objs, objid);
	SVEC_RESIZE(obj->uprefs, n);
	for(size_t i=0;i<n;i++)
		obj->uprefs.data[i].ref = &SVECE(lex->objs, objids[i]);
}

void lex_compute_refs(struct lex *lex){
	compute_downrefs(lex);
	compute_backrefs(lex);
}

size_t lex_get_roots(struct lex *lex, struct obj_def **objs){
	size_t n = 0;

	for(size_t i=0;i<lex->objs.n;i++){
		struct obj_def *obj = &lex->objs.data[i];

		if(IS_ROOT(obj))
			objs[n++] = obj;
	}

	return n;
}

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

static void init_vardefs(struct lex *lex){
	for(lexid i=0;i<lex->vars.n;i++)
		lex->vars.data[i].id = i;
}

static void init_objdefs(struct lex *lex){
	for(lexid i=0;i<lex->objs.n;i++)
		lex->objs.data[i].id = i;
}

static void destroy_objdefs(struct lex *lex){
	for(size_t i=0;i<lex->objs.n;i++){
		struct obj_def *obj = &lex->objs.data[i];

		if(obj->vars.data)
			free(obj->vars.data);

		if(obj->uprefs.data)
			free(obj->uprefs.data);

		if(obj->downrefs.data)
			free(obj->downrefs.data);
	}
}

static void compute_downrefs(struct lex *lex){
	size_t n = lex->objs.n;
	int n_ref[n];
	struct obj_ref downrefs[n][n];

	memset(n_ref, 0, n * sizeof(int));

	for(lexid i=0;i<n;i++){
		struct obj_def *obj = &lex->objs.data[i];

		for(size_t j=0;j<obj->uprefs.n;j++){
			lexid id = obj->uprefs.data[j].ref->id;
			downrefs[id][n_ref[id]++].ref = obj;
		}
	}

	for(lexid i=0;i<n;i++){
		struct obj_def *obj = &lex->objs.data[i];
		SVEC_RESIZE(obj->downrefs, n_ref[i]);
		memcpy(obj->downrefs.data, downrefs[i], SVECSZ(obj->downrefs));
	}
}

static void compute_backrefs(struct lex *lex){
	size_t n = lex->objs.n;
	int upref_idx[n][n];
	int downref_idx[n][n];

#ifdef DEBUG
	memset(upref_idx, -1, sizeof(upref_idx));
	memset(downref_idx, -1, sizeof(downref_idx));
#endif

	for(lexid i=0;i<n;i++){
		struct obj_def *obj = &lex->objs.data[i];

		for(size_t j=0;j<obj->uprefs.n;j++)
			upref_idx[i][obj->uprefs.data[j].ref->id] = (int) j;

		for(size_t j=0;j<obj->downrefs.n;j++)
			downref_idx[i][obj->downrefs.data[j].ref->id] = (int) j;
	}

	for(lexid i=0;i<n;i++){
		struct obj_def *obj = &lex->objs.data[i];

		for(size_t j=0;j<obj->uprefs.n;j++){
			struct obj_ref *upref = &obj->uprefs.data[j];
			upref->back_idx = downref_idx[upref->ref->id][i];

			assert(upref->back_idx >= 0);
			assert(upref->ref->downrefs.data[upref->back_idx].ref == obj);
		}

		for(size_t j=0;j<obj->downrefs.n;j++){
			struct obj_ref *downref = &obj->downrefs.data[j];
			downref->back_idx = upref_idx[downref->ref->id][i];

			assert(downref->back_idx >= 0);
			assert(downref->ref->uprefs.data[downref->back_idx].ref == obj);
		}
	}
}
