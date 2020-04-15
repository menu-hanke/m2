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
typedef uintptr_t fhkG_mapV;

// (TODO?) this same mechanism can be used to implemenet iteration etc. in Lua
// (or anywhere outside graph_solve.c):
// just have a fhkG_map_iter-type struct but begin and next are interrupt handles

struct fhkG_map_iter {
	bool (*begin)(void *state);
	bool (*next)(void *state);
};

struct fhkM_iter_range {
	struct fhkG_map_iter iter;
	unsigned len, idx;
};

struct fhkM_vecV {
	uint16_t offset;
	uint16_t stride;
	uint16_t band;
	struct vec **vec;
	unsigned *idx;
};

typedef struct fhkG_solver fhkG_solver;

/* graph_map.c */
void fhkG_hook_root(struct fhk_graph *G);
void fhkG_hook_solver(struct fhk_graph *root, struct fhk_graph *G);
struct fhk_graph *fhkG_root_graph(struct fhk_graph *G);
void fhkG_set_nameV(struct fhk_graph *G, unsigned idx, const char *name);
const char *fhkG_nameV(struct fhk_graph *G, unsigned idx);
void fhkG_set_nameM(struct fhk_graph *G, unsigned idx, const char *name);
const char *fhkG_nameM(struct fhk_graph *G, unsigned idx);

void fhkM_mapM(struct fhk_graph *G, unsigned idx, struct model *m);
void fhkM_mapV(struct fhk_graph *G, unsigned idx, fhkG_mapV v);
unsigned fhkM_mapV_type(fhkG_mapV v);
fhkG_mapV fhkM_pack_intV(unsigned type, fhkG_handle handle);
fhkG_mapV fhkM_pack_ptrV(unsigned type, void *p);
fhkG_mapV fhkM_pack_vecV(unsigned type, struct fhkM_vecV *v);
void fhkM_range_init(struct fhkM_iter_range *iv);

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

struct fhk_graph *fhkG_solver_graph(fhkG_solver *S);
bool fhkG_solver_is_iter(fhkG_solver *S);
void fhkG_solver_set_reset(fhkG_solver *S, bm8 *reset_v, bm8 *reset_m);
void fhkG_solver_bind(fhkG_solver *S, unsigned vidx, pvalue *buf);
pvalue **fhkG_solver_binds(fhkG_solver *S);
