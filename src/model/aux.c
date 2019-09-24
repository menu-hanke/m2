#define _GNU_SOURCE // for vasprintf

#include "model.h"
#include "../list.h"

#include <stdarg.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <math.h>

struct file_udata {
	const char *filename;
	void *udata;
};

static VEC(struct file_udata) loaded_files;
static const char *last_error = NULL;

static struct file_udata *find_loaded(const char *file);

void *maux_get_file_data(const char *file){
	struct file_udata *f = find_loaded(file);
	return f ? f->udata : NULL;
}

void maux_set_file_data(const char *file, void *udata){
	if(!VECS(loaded_files))
		VEC_INIT(loaded_files, 10);

	struct file_udata *f = find_loaded(file);
	if(!f){
		// this will be leaked because it is never removed
		f = VEC_ADD(loaded_files);
		char *fname = malloc(strlen(file)+1);
		strcpy(fname, file);
		f->filename = fname;
	}

	f->udata = udata;
}

void maux_initmodel(
	struct model *m, const struct model_func *func,
	unsigned n_arg, type *atypes,
	unsigned n_ret, type *rtypes,
	unsigned n_coef, unsigned flags){

	m->func = func;
	m->flags = flags;
	m->n_arg = n_arg;
	m->n_ret = n_ret;
	m->n_coef = n_coef;
	m->atypes = malloc(n_arg * sizeof(type));
	m->rtypes = malloc(n_ret * sizeof(type));
	memcpy(m->atypes, atypes, n_arg * sizeof(type));
	memcpy(m->rtypes, rtypes, n_ret * sizeof(type));

	if(n_coef){
		m->coefs = malloc(n_coef * sizeof(*m->coefs));
		for(unsigned i=0;i<n_coef;i++)
			m->coefs[i] = NAN;
	}else{
		m->coefs = NULL;
	}
}

void maux_destroymodel(struct model *m){
	free(m->atypes);
	free(m->rtypes);
	if(m->coefs)
		free(m->coefs);
}

void maux_exportd(struct model *m, pvalue *argv){
	for(unsigned i=0;i<m->n_arg;i++)
		argv[i].f64 = vexportd(argv[i], m->atypes[i]);
}

void maux_importd(struct model *m, pvalue *retv){
	for(unsigned i=0;i<m->n_ret;i++)
		retv[i] = vimportd(retv[i].f64, m->rtypes[i]);
}

void maux_errf(const char *fmt, ...){
	if(last_error)
		free((void *)last_error);

	va_list ap;
	va_start(ap, fmt);
	vasprintf((char **) &last_error, fmt, ap);
	va_end(ap);
}

const char *model_error(){
	return last_error;
}

static struct file_udata *find_loaded(const char *file){
	for(size_t i=0;i<VECN(loaded_files);i++){
		struct file_udata *f = &VECE(loaded_files, i);
		if(!strcmp(f->filename, file))
			return f;
	}

	return NULL;
}
