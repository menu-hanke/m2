#include <stdlib.h>
#include <string.h>

#include "exec_aux.h"
#include "lex.h"
#include "list.h"

struct exa_file {
	const char *filename;
	void *udata;
};

static VEC(struct exa_file) loaded_files;

static struct exa_file *find_loaded(const char *file);

int ex_exec(struct ex_func *f, pvalue *ret, pvalue *argv){
	return f->impl->exec(f, ret, argv);
}

void ex_destroy(struct ex_func *f){
	f->impl->destroy(f);
}

void *exa_get_file_data(const char *file){
	struct exa_file *f = find_loaded(file);
	return f ? f->udata : NULL;
}

void exa_set_file_data(const char *file, void *udata){
	if(!VECS(loaded_files))
		VEC_INIT(loaded_files, 10);

	struct exa_file *f = find_loaded(file);
	if(!f){
		// this will be leaked because it is never removed
		f = VEC_ADD(loaded_files);
		char *fname = malloc(strlen(file)+1);
		strcpy(fname, file);
		f->filename = fname;
	}

	f->udata = udata;
}

double exa_export_double1(ptype argt, pvalue arg){
	switch(argt){
		case PT_REAL: return arg.r;
		case PT_BIT:  return (double) unpackenum(arg.b);
		case PT_BOOL: return (double) !!arg.b;
		case PT_ID:   return (double) arg.id;
		default:      UNREACHABLE();
	}
}

void exa_export_double(unsigned narg, ptype *argt, pvalue *argv){
	for(unsigned i=0;i<narg;i++)
		argv[i].r = exa_export_double1(argt[i], argv[i]);
}

pvalue exa_import_double1(ptype rett, double ret){
	pvalue r;

	switch(rett){
		case PT_REAL: r.r  = ret; break;
		case PT_BIT:  r.b  = packenum((uint64_t) ret); break;
		case PT_BOOL: r.b  = !!ret; break;
		case PT_ID:   r.id = (uint64_t) ret; break;
		default:      UNREACHABLE();
	}

	return r;
}

void exa_import_double(unsigned nret, ptype *rett, pvalue *retv){
	for(unsigned i=0;i<nret;i++)
		retv[i] = exa_import_double1(rett[i], retv[i].r);
}

void exa_init_prototype(struct exa_prototype *p, unsigned narg, ptype *argt, unsigned nret,
		ptype *rett){

	p->narg = narg;
	p->nret = nret;

	p->argt = malloc(narg * sizeof(ptype));
	p->rett = malloc(nret * sizeof(ptype));
	memcpy(p->argt, argt, narg * sizeof(ptype));
	memcpy(p->rett, rett, nret * sizeof(ptype));
}

void exa_destroy_prototype(struct exa_prototype *p){
	free(p->argt);
	free(p->rett);
}

static struct exa_file *find_loaded(const char *file){
	for(size_t i=0;i<VECN(loaded_files);i++){
		struct exa_file *f = &VECE(loaded_files, i);
		if(!strcmp(f->filename, file))
			return f;
	}

	return NULL;
}
