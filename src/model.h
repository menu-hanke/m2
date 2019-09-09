#pragma once

#include "type.h"

enum {
	MODEL_CALL_OK             = 0,
	MODEL_CALL_RUNTIME_ERROR  = 1,
	MODEL_CALL_INVALID_RETURN = 2
};

enum {
	MODEL_CALIBRATED  = 0x1,
	MODEL_INTERPOLATE = 0x2
};

typedef struct model model;

typedef int (*model_call_f)(model *, pvalue *ret, pvalue *argv);
typedef void (*model_calibrate_f)(model *);
typedef void (*model_destroy_f)(model *);

struct model_func {
	model_call_f call;
	model_calibrate_f calibrate;
	model_destroy_f destroy;
};

struct model {
	const struct model_func *func;
	unsigned flags;
	unsigned n_arg;
	unsigned n_ret;
	unsigned n_coef;
	type *atypes;
	type *rtypes;
	double *coefs;
	// interpolation info goes here if needed?
};

#define MODEL_ISCALIBRATED(m) (((m)->flags & MODEL_CALIBRATED) && (m)->n_coef > 0)
#define MODEL_CALL(m,r,a)     ((m)->func->call((m), (r), (a)))
#define MODEL_CALIBRATE(m)    (m)->func->calibrate(m)
#define MODEL_DESTROY(m)      (m)->func->destroy(m)

const char *model_error();
