#define _GNU_SOURCE // for vasprintf

#include "fff.h"
#include "def.h"

#include <stdarg.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>

void fff_errprintf(struct fff_state *F, const char *fmt, ...){
	if(F->emsg)
		free(F->emsg);

	va_list ap;
	va_start(ap, fmt);
	if(vasprintf(&F->emsg, fmt, ap) < 0){
		F->emsg = NULL;
		F->ecode = FFF_ERR_MEM;
	}
	va_end(ap);
}
