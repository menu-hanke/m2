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

enum {
	FHKD_ECONV = -3,    // type conversion failed
	FHKD_EMOD = -2,     // model call failed
	FHKD_EFHK = -1      // fhk failed
	// >=0 is the corresponding FHKS_* interrupt
};

union fhkD_status {
	// FHKD_ECONV: this is a bug (eg. someone passed an invalid ctype)

	// FHKD_EMOD:
	struct {
		int error;
		// use model_error() to get the error message
	} emod;

	// FHKD_EFHK:
	struct {
		int error;
		int flags;
		struct fhk_ei *ei;
	} efhk;

	// FHKS_*
	struct {
		uint16_t handle;
		uint16_t instance;

		union {
			fhk_subset *map_ss; // FHKS_MAPPING*
			int xi;             // FHKS_COMPUTE_GIVEN
		};
	} interrupt;
};

int fhkD_continue(fhk_solver *S, void *udata, arena *arena, union fhkD_status *stat);
