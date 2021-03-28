#include "def.h"
#include "lang.h"

#include <stdlib.h>
#include <stddef.h>

struct fff_state *fff_create(){
	return calloc(1, sizeof(struct fff_state));
}

void fff_destroy(struct fff_state *F){
#define VMDESTROY(name, type) fff##name##_destroy(F);
	FFF_vmdef(VMDESTROY);
#undef VMDESTROY
	fff_clear_error(F);
	free(F);
}

int32_t fff_ecode(struct fff_state *F){
	return F->ecode;
}

const char *fff_errmsg(struct fff_state *F){
	return F->emsg;
}

void fff_clear_error(struct fff_state *F){
	if(F->emsg)
		free(F->emsg);
	F->ecode = 0;
	F->emsg = NULL;
}
