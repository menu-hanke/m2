#pragma once

#include "../../fhk/fhk.h"
#include "../../model/model.h"
#include "../../model/conv.h"

#include <stdint.h>
#include <stdbool.h>

typedef uint16_t fhkD_lhandle;

// ---- varcalls ----------------------------------------

struct fhkD_driver;
typedef void *(*fhkD_var_f)(struct fhkD_driver *D, void *arg, fhk_eref vref);

enum {
	FHKDV_FP,
	FHKDV_LUA,
	FHKDV_REFK,
	FHKDV_REFU
};

typedef struct fhkD_given {
	uint8_t tag;
	bool trace;

	// FHKDV_REF*
	union {
		uint8_t r_num;
	};

	union {
		// FHKDV_FP
		struct {
			fhkD_var_f fp;
			void *fp_arg;
		};

		// FHKDV_LUA
		fhkD_lhandle l_handle;

		// FHKDV_REF*
		struct {
			union {
				void *rk_ref;      // FHKDV_REFK
				uint16_t ru_udata; // FHKDV_REFU
			};
			uint16_t r_off[4];
		};
	};
} fhkD_given;

// ---- modcalls ----------------------------------------

enum {
	FHKDM_FP,
	FHKDM_MCALL,
	FHKDM_LUA
};

typedef struct fhkD_conv {
	uint8_t ei;
	mt_type from;
	mt_type to;
} fhkD_conv;

typedef struct fhkD_model {
	uint8_t tag;
	bool trace;

	union {
		// FHKDM_MCALL
		struct {
			uint16_t m_npconv;
			uint16_t m_nconv;
		};
	};

	union {
		// FHKDM_FP (TODO)

		// FHKDM_MCALL
		struct {
			mcall_fp m_fp;
			void *m_model;
			fhkD_conv *m_conv;
		};

		// FHKDM_LUA (TODO)
	};
} fhkD_model;

// ---- mappings ----------------------------------------

typedef fhk_subset (*fhkD_map_f)(fhk_idx map, void *arg, fhk_inst instance);

enum {
	FHKDP_FP,
	FHKDP_LUA
};

typedef struct fhkD_map {
	uint8_t tag;
	bool trace;

	union {
		// FHKDP_FP (TODO)
		fhkD_map_f fp[2];

		// FHKDP_LUA
		fhkD_lhandle l_handle[2];
	};
} fhkD_map;

// ------------------------------------------------------------

typedef struct fhkD_mapping {
	union {
		fhkD_model *models;
		fhkD_given *vars;        // note: only given. you must rearrange your vars so that given
								 //       variables come first
	};
	fhkD_map *maps;
} fhkD_mapping;

enum {
	FHKDE_MOD = -3,  // model call failed (model crashed etc., see model_error())
	FHKDE_CONV = -2, // invalid conversion
	FHKDE_FHK = -1,  // fhk error (check e_status)
	FHKD_OK = 0,

	FHKDL_VAR,       // run a lua callback
	FHKDL_MODEL,     //
	FHKDL_MAP,       //
	FHKDL_TRACE      //
};

typedef union fhkD_status {
	// FHKDE_FHK
	fhk_status e_status;

	// FHKDL_VAR
	struct {
		fhkD_lhandle v_handle;
		fhk_inst v_inst;
	};

	// FHKDL_MODEL (TODO)

	// FHKDL_MAP
	struct {
		fhkD_lhandle p_handle;
		fhk_inst p_inst;
		fhk_subset *p_ss;
	};
} fhkD_status;

typedef struct fhkD_driver {
	fhkD_mapping M;
	fhk_solver *S;
	arena *mem;
	fhkD_status status;
	fhk_status tr_status;
	bool trace;
	uint8_t umem[] __attribute__((aligned(16)));
} fhkD_driver;

fhkD_driver *fhkD_create_driver(fhkD_mapping *M, size_t n_umem, fhk_solver *S, arena *mem);
int32_t fhkD_continue(fhkD_driver *D);
