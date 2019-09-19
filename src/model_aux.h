#pragma once

#include "model.h"
#include "type.h"

#include <stdarg.h>

void *maux_get_file_data(const char *file);
void maux_set_file_data(const char *file, void *udata);
void maux_initmodel(
		struct model *m, const struct model_func *func,
		unsigned n_arg, type *atypes,
		unsigned n_ret, type *rtypes,
		unsigned n_coef, unsigned flags
);
void maux_destroymodel(struct model *m);
void maux_exportd(struct model *m, pvalue *argv);
void maux_importd(struct model *m, pvalue *retv);
void maux_errf(const char *fmt, ...);

#define MODEL_INIT_DEF\
	unsigned n_arg;\
	unsigned n_ret;\
	type *atypes;\
	type *rtypes;\
	unsigned flags
