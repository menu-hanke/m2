#include "../../fhk/fhk.h"
#include "../../def.h"
#include "driver.h"

#include <stdint.h>
#include <stddef.h>
#include <assert.h>

static_assert(FHKS_MAPCALL - FHKS_VREF == 1);
static_assert(FHKS_MODCALL - FHKS_VREF == 2);

int32_t fhkD_continue(fhk_solver *S, fhkD_dispatch *D){
	fhk_status status = fhk_continue(S);

	fhk_sarg arg = FHK_ARG(status);
	uint32_t code = FHK_CODE(status);
	D->arg = arg;

	if(UNLIKELY(code < FHKS_VREF))
		return !!code;

	uint16_t *dispatch = D->jumptables[code - FHKS_VREF];
	int32_t idx = (code == FHKS_MODCALL) ? ((fhk_eref *) (uintptr_t) arg.u64)->idx : arg.s_vref.idx;
	return dispatch[idx];
}

void fhkD_setvaluei_u64(fhk_solver *S, fhk_idx xi, fhk_inst inst, uint32_t num, uintptr_t p){
	fhkS_setvaluei(S, xi, inst, num, (void *) p);
}

void fhkD_setvaluei_offset(fhk_solver *S, fhk_idx xi, fhk_inst inst, uint32_t num, void *p,
		uint32_t offset){
	fhkS_setvaluei(S, xi, inst, num, p+offset);
}
