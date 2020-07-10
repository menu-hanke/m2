#pragma once

#include "driver.h"
#include "../../fhk/fhk.h"

#include <stdint.h>

struct fhkM_va_refk {
	struct fhkD_cvar _cv;
	void *k;
	uint16_t n;
	uint16_t offset[];
};

struct fhkM_va_deref {
	struct fhkD_cvar _cv;
	uint16_t n;
	uint16_t offset[];
};

void fhkM_va_derefk_f(fhk_solver *S, struct fhkM_va_refk *ref, void *_ud, int xi, int _inst);
void fhkM_va_deref_f(fhk_solver *S, struct fhkM_va_deref *ref, void *p, int xi, int _inst);
