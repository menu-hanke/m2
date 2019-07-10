#pragma once

#include "lex.h"

#include <stddef.h>
#include <stdint.h>

typedef int (*ex_exec_f)(void *, union pvalue *ret, union pvalue *argv);

typedef struct ex_info {
	ex_exec_f exec;
} ex_info;

#ifdef M2_EXEC_R
typedef struct ex_R_info ex_R_info;
ex_R_info *ex_R_create(const char *fname, const char *func,
		int narg, enum ptype *argt, int nret, enum ptype *rett);
int ex_R_exec(ex_R_info *X, union pvalue *ret, union pvalue *argv);
void ex_R_destroy(ex_R_info *X);
#endif

#define ex_exec(ei, ret, argv) ((ex_info *) (ei))->exec((ei), (ret), (argv))
