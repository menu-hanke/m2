#pragma once

#include "model.h"
#include "model_aux.h"
#include "type.h"

enum mod_R_calib_mode {
	MOD_R_EXPAND,
	MOD_R_PASS_VECTOR
	/* MOD_R_PASS_MATRIX ? */
};

struct mod_R_def {
	MODEL_INIT_DEF;
	const char *fname;
	const char *func;
	unsigned n_coef;
	enum mod_R_calib_mode mode;
	/* coef matrix dimensions, if using matrix ? */
};

model *mod_R_create(struct mod_R_def *def);
