#pragma once

#include "../../fhk/fhk.h"

#include <stdint.h>
#include <stddef.h>

typedef struct fhkD_dispatch {
	union {
		struct {
			uint16_t *vref;
			uint16_t *mapcall;
			uint16_t *modcall;
		};
		uint16_t *jumptables[3];
	};

	// relevant part of fhk_sarg
	union {
		fhk_sarg arg;
		fhk_eref arg_ref;
		void *arg_ptr;
	};
} fhkD_dispatch;

int32_t fhkD_continue(fhk_solver *S, fhkD_dispatch *D);

// wrappers to reduce type-cast ceremonies
void fhkD_setvaluei_u64(fhk_solver *S, fhk_idx xi, fhk_inst inst, uint32_t num, uintptr_t p);
void fhkD_setvaluei_offset(fhk_solver *S, fhk_idx xi, fhk_inst inst, uint32_t num, void *p,
		uint32_t offset);
