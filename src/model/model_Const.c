/* model that always returns a constant value - this is mainly useful for testing */

#include "model_Const.h"

#include <stdlib.h>
#include <stddef.h>
#include <string.h>

struct model_Const {
	struct model model;
	pvalue ret[];
};

static int mod_Const_call(struct model_Const *m, pvalue *ret, pvalue *argv);

static const struct model_func MOD_CONST = {
	.call      = (model_call_f) mod_Const_call,
	.calibrate = NULL,
	.destroy   = (model_destroy_f) free
};

model *mod_Const_create(unsigned nret, pvalue *ret){
	struct model_Const *m = malloc(sizeof(*m) + nret*sizeof(*ret));
	memset(&m->model, 0, sizeof(m->model));
	m->model.func = &MOD_CONST;
	m->model.n_ret = nret;
	// don't need to set rtypes, we don't care about them
	memcpy(m->ret, ret, nret*sizeof(*ret));
	return (model *) m;
}

static int mod_Const_call(struct model_Const *m, pvalue *ret, pvalue *argv){
	(void)argv;
	memcpy(ret, m->ret, m->model.n_ret*sizeof(*ret));
	return MODEL_CALL_OK;
}
