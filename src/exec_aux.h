#include "type.h"

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
	type *argt;
	unsigned nret;
	type *rett;
};

void *exa_get_file_data(const char *file);
void exa_set_file_data(const char *file, void *udata);
double exa_export_double1(type argt, pvalue arg);
void exa_export_double(unsigned narg, type *argt, pvalue *argv);
pvalue exa_import_double1(type rett, double ret);
void exa_import_double(unsigned nret, type *rett, pvalue *retv);
// void exa_file_remove_data
void exa_init_prototype(struct exa_prototype *p, unsigned narg, type *argt, unsigned nret,
		type *rett);
void exa_destroy_prototype(struct exa_prototype *p);
