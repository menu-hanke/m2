#pragma once

#include <stdint.h>
#include <stddef.h>
#include <stdalign.h>
#include <stdbool.h>

typedef struct sim sim;
typedef uint64_t sim_branchid;

enum {
	SIM_STATIC,
	SIM_FRAME,
	SIM_VSTACK
};

enum {
	SIM_SKIP = -1, // skip branch (not an error)
	SIM_OK = 0,
	SIM_EFRAME,    // invalid frame
	SIM_ESAVE,     // invalid save state
	SIM_EALLOC,    // unable to allocate memory
	SIM_EBRANCH    // invalid branch point
};

enum {
	SIM_MULTIPLE = 1
};

sim *sim_create();
void sim_destroy(sim *sim);

void *sim_alloc(sim *sim, size_t sz, size_t align, int lifetime);
unsigned sim_frame_id(sim *sim);

int sim_enter(sim *sim);
int sim_exit(sim *sim);
int sim_savepoint(sim *sim);
int sim_restore(sim *sim);
int sim_branch(sim *sim, int hint);
int sim_take_branch(sim *sim, sim_branchid id);
