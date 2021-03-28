#pragma once

#include "fff.h"

fff_handle fffR_create(fff_state *F, const char *file, const char *func, const char *signature);
int32_t fffR_call(fff_state *F, fff_handle func, fhk_modcall *call);
