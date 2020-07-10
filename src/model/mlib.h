#pragma once

#if 0
#include "model.h"

#include <stdarg.h>

void *mlib_get_file_data(const char *file);
void mlib_set_file_data(const char *file, void *udata);
void mlib_initmodel(
		struct model *m, const struct model_func *func,
		unsigned n_arg, type *atypes,
		unsigned n_ret, type *rtypes,
		unsigned n_coef, unsigned flags
);
void mlib_destroymodel(struct model *m);
void mlib_exportd(struct model *m, pvalue *argv);
void mlib_importd(struct model *m, pvalue *retv);
void mlib_errf(const char *fmt, ...);

#define MODEL_INIT_DEF\
	unsigned n_arg;\
	unsigned n_ret;\
	type *atypes;\
	type *rtypes;\
	unsigned flags
#endif
