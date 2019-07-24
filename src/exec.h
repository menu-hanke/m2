#pragma once

#include "lex.h"

#include <stddef.h>
#include <stdint.h>

typedef int (*ex_exec_f)(void *, pvalue *ret, pvalue *argv);
typedef void (*ex_destroy_f)(void *);

struct ex_impl {
	ex_exec_f exec;
	ex_destroy_f destroy;
};

typedef struct ex_func {
	const struct ex_impl *impl;
} ex_func;

#ifdef M2_EXEC_R
ex_func *ex_R_create(const char *fname, const char *func, int narg, ptype *argt, int nret,
		ptype *rett);
#endif

#define ex_exec(f, ret, argv) (f)->impl->exec((f), (ret), (argv))
#define ex_destroy(f) (f)->impl->destroy(f)
