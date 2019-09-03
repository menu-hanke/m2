#include <stdlib.h>
#include <string.h>

#include "exec_aux.h"
#include "type.h"
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

void exa_export_double(unsigned narg, type *argt, pvalue *argv){
	for(unsigned i=0;i<narg;i++)
		argv[i].f64 = vexportd(argv[i], argt[i]);
}

void exa_import_double(unsigned nret, type *rett, pvalue *retv){
	for(unsigned i=0;i<nret;i++)
		retv[i] = vimportd(retv[i].f64, rett[i]);
}

void exa_init_prototype(struct exa_prototype *p, unsigned narg, type *argt, unsigned nret,
		type *rett){

	p->narg = narg;
	p->nret = nret;

	p->argt = malloc(narg * sizeof(type));
	p->rett = malloc(nret * sizeof(type));
	memcpy(p->argt, argt, narg * sizeof(type));
	memcpy(p->rett, rett, nret * sizeof(type));

	for(unsigned i=0;i<narg;i++)
		assert(argt[i] == TYPE_PROMOTE(argt[i]));

	for(unsigned i=0;i<nret;i++)
		assert(rett[i] == TYPE_PROMOTE(rett[i]));
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
