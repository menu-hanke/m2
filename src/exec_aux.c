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
	if(!f)
		f = VEC_ADD(loaded_files);

	f->udata = udata;
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
