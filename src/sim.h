#pragma once

#include <stdint.h>
#include <stddef.h>
#include <stdalign.h>
#include <stdbool.h>

typedef struct sim sim;

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
	SIM_CREATE_SAVEPOINT = 1,
	SIM_TAILCALL = 1
};

sim *sim_create(uint32_t nframe, uint32_t rsize);
void sim_destroy(sim *sim);

void *sim_alloc(sim *sim, size_t sz, size_t align, int lifetime);
uint32_t sim_fp(sim *sim);
uint32_t sim_frame_id(sim *sim);

int sim_savepoint(sim *sim);
int sim_load(sim *sim, uint32_t fp);
int sim_up(sim *sim, uint32_t fp);
int sim_reload(sim *sim);
int sim_enter(sim *sim);

int sim_branch(sim *sim, int hint);
int sim_enter_branch(sim *sim, uint32_t fp, int hint);
int sim_exit_branch(sim *sim);
