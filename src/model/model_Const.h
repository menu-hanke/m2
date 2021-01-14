#pragma once

#include "model.h"

#include <stddef.h>
#include <stdbool.h>

typedef struct mod_Const mod_Const;

uint64_t mod_Const_types();
mod_Const *mod_Const_create(size_t num, size_t *nr, void **rv);
bool mod_Const_call(mod_Const *M, mcall_s *mc);
void mod_Const_destroy(mod_Const *M);
