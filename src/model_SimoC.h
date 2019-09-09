#pragma once

#include "model.h"
#include "model_aux.h"
#include "type.h"

struct mod_SimoC_def {
	MODEL_INIT_DEF;
	const char *libname;
	const char *func;
};

model *mod_SimoC_create(struct mod_SimoC_def *def);
