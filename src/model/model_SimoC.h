#pragma once

#include "mlib.h"

struct mod_SimoC_def {
	MODEL_INIT_DEF;
	const char *libname;
	const char *func;
};

model *mod_SimoC_create(struct mod_SimoC_def *def);
