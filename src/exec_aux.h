#include "lex.h"

typedef int (*ex_exec_f)(void *, pvalue *ret, pvalue *argv);
typedef void (*ex_destroy_f)(void *);

struct ex_impl {
	ex_exec_f exec;
	ex_destroy_f destroy;
};

struct ex_func {
	const struct ex_impl *impl;
};

struct exa_prototype {
	unsigned narg;
	ptype *argt;
	unsigned nret;
	ptype *rett;
};

void *exa_get_file_data(const char *file);
void exa_set_file_data(const char *file, void *udata);
// void exa_file_remove_data
void exa_init_prototype(struct exa_prototype *p, unsigned narg, ptype *argt, unsigned nret,
		ptype *rett);
void exa_destroy_prototype(struct exa_prototype *p);
