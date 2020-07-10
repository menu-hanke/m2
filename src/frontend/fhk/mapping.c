#include "mapping.h"
#include "../../fhk/fhk.h"

#include <stdint.h>

void fhkM_va_derefk_f(fhk_solver *S, struct fhkM_va_refk *ref, void *_ud, int xi, int _inst){
	(void)_ud;
	(void)_inst;

	void *p = ref->k;

	for(size_t i=0;i<ref->n;i++)
		p = *(void **)p + ref->offset[i];

	fhkS_give_all(S, xi, ref->k);
}

void fhkM_va_deref_f(fhk_solver *S, struct fhkM_va_deref *ref, void *p, int xi, int _inst){
	(void)_inst;

	for(size_t i=0;i<ref->n;i++)
		p = *(void **)p + ref->offset[i];

	fhkS_give_all(S, xi, p);
}
