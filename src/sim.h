#pragma once

#include "lex.h"
#include "grid.h"

#include <stddef.h>
#include <stdint.h>

typedef struct sim sim;
typedef uint64_t sim_branchid;

#define SIM_NO_BRANCH 0

typedef struct sim_objvec {
	size_t n_alloc;
	size_t n_used;
	size_t n_bands;
	struct tvec bands[];
} sim_objvec;

typedef struct sim_objref {
	sim_objvec *vec;
	size_t idx;
} sim_objref;

sim *sim_create(struct lex *lex);
void sim_destroy(sim *sim);

struct grid *sim_get_envgrid(sim *sim, lexid envid);
struct grid *sim_get_objgrid(sim *sim, lexid objid);
size_t sim_env_effective_order(sim *sim, lexid envid);

void *S_obj_varp(sim_objref *ref, lexid varid);
pvalue S_obj_read(sim_objref *ref, lexid varid);
void *S_envp(sim *sim, lexid envid, gridpos pos);
pvalue S_read_env(sim *sim, lexid envid, gridpos pos);
void S_allocv(sim *sim, sim_objref *refs, lexid objid, size_t n, gridpos *pos);
void S_allocvs(sim *sim, sim_objref *refs, lexid objid, size_t n, gridpos *pos);
// TODO: S_deallocv
void S_allocb(sim *sim, struct tvec *v, sim_objvec *vec, lexid varid);

void S_savepoint(sim *sim);
void S_restore(sim *sim);
void S_enter(sim *sim);
void S_exit(sim *sim);
sim_branchid S_branch(sim *sim, size_t n, sim_branchid *branches);
sim_branchid S_next_branch(sim *sim);
