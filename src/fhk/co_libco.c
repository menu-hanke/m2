#include "fhk.h"
#include "def.h"
#include "co_libco.h"

#include <libco.h>
#include <stddef.h>

// libco backend, this is meant only for debugging on windows machines.

static __thread fhk_solver *solver;

fhk_status fhk_continue(fhk_solver *S){
	fhk_co *co = (fhk_co *) S;

	if(!co->co)
		return co->status;

	co->caller = co_active();
	solver = S;
	co_switch(co->co);

	if(co->destroy){
		co_delete(co->co);
		co->co = NULL;
	}

	return co->status;
}

void fhkJ_yield(fhk_solver *S, fhk_status s){
	fhk_co *co = (fhk_co *) S;
	co->status = s;
	co_switch(co->caller);
}

static void S_start(){
	fhk_co *co = (fhk_co *) solver;
	co->fp(solver);
}

void fhk_co_init(fhk_co *co, void *fp){
	co->fp = fp;
	co->co = co_create(FHK_CO_STACK, S_start);
	co->destroy = false;
}

void fhk_co_done(fhk_co *co){
	if(co->co == co_active()){
		co->destroy = true;
	}else{
		co_delete(co->co);
		co->co = NULL;
	}
}
