#pragma once

#include "../mem.h"

// the model ffi has no dependency on fhk, however we use the same model call format to avoid
// unneeded copying.
#include "../fhk/fhk.h"
typedef struct fhks_cmodel mcall_s;
#define mcall_edge typeof(*((mcall_s *)0)->edges)

typedef int (*mcall_fp)(void *, mcall_s *);
#define MCALL_FP(fp) ((mcall_fp) (fp))

#include <stddef.h>

enum {
	MCALL_OK             = 0,
	MCALL_RUNTIME_ERROR  = 1,
	MCALL_INVALID_RETURN = 2
};

void model_errf(const char *fmt, ...);
const char *model_error();
void model_cleanup();
