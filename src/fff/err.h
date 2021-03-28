#pragma once

#include "fff.h"
#include "def.h"

void fff_errprintf(struct fff_state *F, const char *fmt, ...);

#define fff_errsig(F, sig) \
	do { \
		(F)->ecode = FFF_ERR_SIGNATURE; \
		fff_errprintf((F), "invalid signature: %s", (sig)); \
	} while(0)

#define fff_errmem(F) \
	do { \
		(F)->ecode = FFF_ERR_MEM; \
		fff_errprintf((F), "failed to allocate memory"); \
	} while(0)
