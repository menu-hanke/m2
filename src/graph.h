#pragma once

// utilities for connecting the fhk graph with outside world

#include "fhk.h"
#include "type.h"
#include "bitmap.h"
#include "model/model.h"

#include <stdint.h>
#include <stdbool.h>

enum {
	FHKG_RETURN        = 0,
	//FHKG_INTERRUPT_M  = 1 << 30, // model interrupt
	FHKG_INTERRUPT_V   = 1 << 31, // variable interrupt
	FHKG_HANDLE_MASK   = (1 << 16)-1
};

enum {
	FHKG_MAP_INTERRUPT = 0,
	FHKG_MAPPINGS_START,
	FHKG_MAP_COMPUTED  = 0xff
};

enum {
	FHKG_HOOK_VAR        = 0,
	FHKG_HOOK_MODEL      = 4,
	FHKG_HOOK_EXEC       = 0x1,
	FHKG_HOOK_AUTOFAIL   = 0x2,
	FHKG_HOOK_DEBUG      = 0x4,
	FHKG_HOOK_MASK       = 0xf,

	FHKG_HOOK_ALL        = ((FHKG_HOOK_EXEC|FHKG_HOOK_DEBUG)<<FHKG_HOOK_VAR)
		| ((FHKG_HOOK_EXEC|FHKG_HOOK_DEBUG)<<FHKG_HOOK_MODEL),
	FHKG_HOOK_DEBUG_ONLY = ((FHKG_HOOK_AUTOFAIL|FHKG_HOOK_DEBUG)<<FHKG_HOOK_VAR)
		| ((FHKG_HOOK_AUTOFAIL|FHKG_HOOK_DEBUG)<<FHKG_HOOK_MODEL)
};

// Note: this should be 32-bit so it doesn't get boxed by LuaJIT
// result structure:
//     0-15      handle that caused the interrupt
//     16-29     0 (unused)
//     30        (TODO) virtual model:
//                 * fhk wants to execute a model in the sim space (so the usual model calling
//                   protocol will not work)
//                 * model is indicated by handle bits
//     31        virtual variable:
//                 * fhk wants to read a lazy computed variable, indicated by the handle bits 0-15
//                 * fhkG_solver_resumeV MUST be called next with the variable value
typedef uint32_t fhkG_solver_res;
typedef uint16_t fhkG_handle;

#define FHKG_MAPPINGV(...)    \
	union {                   \
		uint64_t u64;         \
		struct {              \
			uint8_t resolve;  \
			uint8_t type;     \
			__VA_ARGS__       \
		};                    \
	} flags;                  \
	const char *name

#define FHKG_FLAGS(v) typeof((v)->flags)

struct fhkG_mappingV {
	FHKG_MAPPINGV();
};

struct fhkG_vintV {
	FHKG_MAPPINGV(fhkG_handle handle;);
};

struct fhkG_mappingM {
	struct model *mod;
	const char *name;
};

// (TODO?) this same mechanism can be used to implemenet iteration etc. in Lua
// (or anywhere outside graph_solve.c):
// just have a fhkG_map_iter-type struct but begin and next are interrupt handles

struct fhkG_map_iter {
	bool (*begin)(void *state);
	bool (*next)(void *state);
};

typedef struct fhkG_solver fhkG_solver;

/* graph_map.c */
void fhkG_hook(struct fhk_graph *G, int what);
void fhkG_bindV(struct fhk_graph *G, unsigned idx, struct fhkG_mappingV *v);
void fhkG_bindM(struct fhk_graph *G, unsigned idx, struct fhkG_mappingM *m);

/* graph_solve.c */
bool fhkG_have_interrupts();
void fhkG_interruptV(fhkG_handle handle, pvalue *v);
// bool fhkG_may_interrupt(struct fhk_graph *G); // TODO

fhkG_solver *fhkG_solver_create(struct fhk_graph *G, unsigned nv, struct fhk_var **xs, bm8 *init_v);
fhkG_solver *fhkG_solver_create_iter(struct fhk_graph *G, unsigned nv, struct fhk_var **xs,
		bm8 *init_v, struct fhkG_map_iter *iter, bm8 *reset_v, bm8 *reset_m);
void fhkG_solver_destroy(fhkG_solver *S);

fhkG_solver_res fhkG_solver_solve(fhkG_solver *S);
fhkG_solver_res fhkG_solver_resumeV(fhkG_solver *S, pvalue iv);

bool fhkG_solver_is_iter(fhkG_solver *S);
void fhkG_solver_set_reset(fhkG_solver *S, bm8 *reset_v, bm8 *reset_m);
void fhkG_solver_bind(fhkG_solver *S, unsigned vidx, pvalue *buf);
pvalue **fhkG_solver_binds(fhkG_solver *S);
