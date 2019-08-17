#pragma once

#include <stdint.h>
#include <stddef.h>
#include <stdalign.h>

typedef struct sim sim;
typedef uint64_t sim_branchid;

typedef enum sim_mem {
	SIM_ALLOC_STATIC = 0,
	SIM_ALLOC_VSTACK = 1,
	SIM_ALLOC_FRAME  = 2
} sim_mem;

#define SIM_NO_BRANCH 0

sim *sim_create();
void sim_destroy(sim *sim);

#define sim_static_malloc(sim, sz) sim_static_alloc(sim, sz, alignof(max_align_t))
void *sim_static_alloc(sim *sim, size_t sz, size_t align);
void *sim_vstack_alloc(sim *sim, size_t sz, size_t align);
void *sim_frame_alloc(sim *sim, size_t sz, size_t align);
void *sim_alloc(sim *sim, size_t sz, size_t align, sim_mem where);

int sim_is_frame_owned(sim *sim, void *p);
unsigned sim_frame_id(sim *sim);

void sim_savepoint(sim *sim);
void sim_restore(sim *sim);
void sim_enter(sim *sim);
void sim_exit(sim *sim);
sim_branchid sim_branch(sim *sim, size_t n, sim_branchid *branches);
sim_branchid sim_next_branch(sim *sim);
