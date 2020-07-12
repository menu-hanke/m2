#pragma once

#include "../../fhk/fhk.h"
#include "../../model/model.h"
#include "../../model/conv.h"

#include <stdint.h>

typedef fhk_subset (*fhkD_cmap_f)(void *cmap, void *arg, int instance);
typedef void (*fhkD_cvar_f)(fhk_solver *S, void *cvar, void *arg, int xi, int instance);

// udata repr:
//     
//               63 .. 48 | 47 .. 33 | 32 | 31 .. 16 | 15 .. 2 | 1 | 0
//             -----------+----------+----+----------+---------+---+----
// C           |  argoff  | - - - -  fhkD_cmap *cm  - - - - - - - - -  |
// C (var)     |  argoff  | - - - -  fhkD_cvar *cv  - - - - - - - - -  |
// C (refka)   |  - - - - - pointer - - - - - - - -  | 1 ... 1 | 1 | 0 |
// C (derefka) |  - - - - - pointer - - - - - - - -  |  offset | 1 | 0 |
// C (derefxa) |  - - - - - insn - - - - - - - - - - |  argoff | 1 | 1 |
// Lua (var)   |  0 .................. 0  | handle   | 0 ... 0 | 0 | 1 |
// Lua (map)   | 0 .... 0 |  handle inv   | hnd map  | 0 ... 0 | 0 | 1 |
//
// keep in sync with driver.c and driver.lua!

struct fhkD_cmap {
	fhkD_cmap_f fp[2]; // { inverse, map }
};

struct fhkD_cvar {
	fhkD_cvar_f fp;
};

struct fhkD_cmodel {
	mcall_fp fp;
	void *model;
	// may be NULL if no conversion
	mt_type *gsig;
	mt_type *msig;
};

struct fhkD_cres {
	int16_t status;
	union {
		struct {
			int16_t handle;
			uint16_t instance;
		};
		struct {
			uint16_t ewhat;
			uint16_t eflags;
		};
	};
	union {
		fhk_subset *map_ss;
		int xi;
		struct fhk_ei *ei;
	};
};

enum {
	FHKD_ERROR = -1,
	FHKD_CONVERSION_FAILED = -1,
	FHKD_MODEL_FAILED = -2
};

// NULL for FHK_OK, non-NULL for callback/error
struct fhkD_cres *fhkD_continue(fhk_solver *S, void *udata, arena *arena);
