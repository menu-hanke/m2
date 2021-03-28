#pragma once

#include "lang.h"

#include <stdint.h>

struct fff_state {
	int32_t ecode;
	char *emsg;

#define VMMEMB(name, type) type vm_##name;
	FFF_vmdef(VMMEMB)
#undef VMMEMB
};
