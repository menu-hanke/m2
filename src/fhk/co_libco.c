#include "fhk.h"
#include "def.h"
#include "co_libco.h"

#include <libco.h>
#include <stddef.h>

// libco backend, this is meant only for debugging on windows machines.

static __thread fhk_solver *solver;

fhk_status fhk_continue(fhk_solver *S){
	fhk_co *C = (fhk_co *) S;

	if(!C->co)
		return co->status;

	C->caller = co_active();
	solver = S;
	co_switch(C->co);

	if(co->destroy){
		co_delete(C->co);
		C->co = NULL;
	}

	return C->status;
}

void fhkJ_yield(fhk_co *C, fhk_status s){
	C->status = s;
	co_switch(C->caller);
}

static void C_start(){
	fhk_co *C = (fhk_co *) solver;
	co->fp(solver);
}

void fhk_co_init(fhk_co *C, void *fp){
	C->fp = fp;
	C->co = co_create(FHK_CO_STACK, C_start);
	C->destroy = false;
}

void fhk_co_done(fhk_co *C){
	if(C->co == co_active()){
		C->destroy = true;
	}else{
		co_delete(C->co);
		C->co = NULL;
	}
}
