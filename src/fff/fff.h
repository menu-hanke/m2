#pragma once

#include "../fhk/fhk.h"

#include <stdint.h>

typedef uintptr_t fff_handle;
typedef struct fff_state fff_state;
typedef int32_t (*fff_func)(fff_state *F, fff_handle handle, fhk_modcall *call);

enum {
	FFF_OK = 0,
	FFF_ERR_MEM,
	FFF_ERR_SIGNATURE,
	FFF_ERR_CRASH
};

fff_state *fff_create();
void fff_destroy(fff_state *F);
int32_t fff_ecode(fff_state *F);
const char *fff_errmsg(fff_state *F);
void fff_clear_error(fff_state *F);
