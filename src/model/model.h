#pragma once

#include "../mem.h"

#include <stddef.h>

typedef struct mcall_edge {
	void *p;
	size_t n;
} mcall_edge;

typedef struct mcall_s {
	uint8_t np, nr;
	mcall_edge edges[];
} mcall_s;

typedef int (*mcall_fp)(void *, mcall_s *);
#define MCALL_FP(fp) ((mcall_fp) (fp))

enum {
	MCALL_OK             = 0,
	MCALL_RUNTIME_ERROR  = 1,
	MCALL_INVALID_RETURN = 2
};

void model_errf(const char *fmt, ...);
const char *model_error();
void model_cleanup();
