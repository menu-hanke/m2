#pragma once

#include "../mem.h"

#include <stddef.h>
#include <stdbool.h>

typedef struct mcall_edge {
	void *p;
	size_t n;
} mcall_edge;

typedef struct mcall_s {
	uint8_t np, nr;
	mcall_edge edges[];
} mcall_s;

typedef bool (*mcall_fp)(void *, mcall_s *);
#define MCALL_FP(fp) ((mcall_fp) (fp))

void model_errf(const char *fmt, ...);
const char *model_error();
void model_cleanup();
