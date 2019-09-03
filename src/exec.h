#pragma once

#include "type.h"

#include <stddef.h>
#include <stdint.h>

typedef struct ex_func ex_func;

int ex_exec(ex_func *f, pvalue *ret, pvalue *argv);
void ex_destroy(ex_func *f);

#ifdef M2_EXEC_R
ex_func *ex_R_create(const char *fname, const char *func, int narg, type *argt, int nret,
		type *rett);
#endif

#ifdef M2_EXEC_SIMOC
ex_func *ex_simoC_create(const char *libname, const char *func, int narg, type *argt, int nret,
		type *rett);
#endif
