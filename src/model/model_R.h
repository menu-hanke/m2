#pragma once

#include "model.h"
#include "conv.h"

#include <stdint.h>
#include <stdbool.h>

typedef struct mod_R mod_R;

uint64_t mod_R_types();
mod_R *mod_R_create(const char *file, const char *func, struct mt_sig *sig);
// void mod_R_calibrate(mod_R *m, size_t n_co, double *co); // TODO
bool mod_R_call(mod_R *m, mcall_s *mc);
void mod_R_destroy(mod_R *m);
void mod_R_cleanup();
