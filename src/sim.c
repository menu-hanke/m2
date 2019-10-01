#include "arena.h"
#include "def.h"
#include "sim.h"

#include <stddef.h>
#include <stdlib.h>
#include <stdalign.h>
#include <stdbool.h>
#include <string.h>
#include <assert.h>

struct branchinfo {
	unsigned nb;
	unsigned next;
	sim_branchid ids[];
};

struct frame {
	unsigned init   : 1;
	unsigned inside : 1;
	unsigned saved  : 1;
	unsigned dirty  : 1;
	unsigned fid;
	arena *arena;
	size_t vstack_ptr;
	void *vstack_copy;
	struct branchinfo *branches;
};

struct sim {
	arena *static_arena;

	unsigned next_fid;
	unsigned depth;
	struct frame fstack[SIM_MAX_DEPTH];
	uint8_t vstack[SIM_VSTACK_SIZE] __attribute__((aligned(M2_VECTOR_SIZE)));
};

static void init_frame(struct sim *sim);
static void destroy_stack(struct sim *sim);

#define TOP(sim) (&((sim)->fstack[(sim)->depth]))
#define PREV(sim) (&((sim)->fstack[({ assert((sim)->depth>0); (sim)->depth-1; })]))
static void f_init(struct frame *f);
static void f_destroy(struct frame *f);
static void f_enter(struct frame *f, unsigned fid);
static size_t f_salloc(struct frame *f, size_t sz, size_t align);
static void f_branch(struct frame *f, size_t n, sim_branchid *ids);
static bool f_next_branch(struct frame *f);
static void f_exit(struct frame *f);
static void *f_alloc(struct frame *f, size_t size, size_t align);

struct sim *sim_create(){
	arena *static_arena = arena_create(SIM_STATIC_ARENA_SIZE);
	struct sim *sim = arena_alloc(static_arena, sizeof(*sim), alignof(*sim));
	sim->static_arena = static_arena;
	memset(sim->fstack, 0, sizeof(sim->fstack));
	init_frame(sim);
	return sim;
}

void sim_destroy(struct sim *sim){
	destroy_stack(sim);
	arena_destroy(sim->static_arena);
}

void *sim_static_alloc(struct sim *sim, size_t sz, size_t align){
	return arena_alloc(sim->static_arena, sz, align);
}

void *sim_vstack_alloc(struct sim *sim, size_t sz, size_t align){
	size_t p = f_salloc(TOP(sim), sz, align);
	return &sim->vstack[p];
}

void *sim_frame_alloc(struct sim *sim, size_t sz, size_t align){
	return f_alloc(TOP(sim), sz, align);
}

void *sim_alloc(struct sim *sim, size_t sz, size_t align, int lifetime){
	static void *(*const allocf[])(struct sim *, size_t, size_t) = {
		[0]                      = sim_static_alloc,
		[SIM_MUTABLE]            = NULL,
		[SIM_FRAME]              = sim_frame_alloc,
		[SIM_MUTABLE|SIM_FRAME]  = sim_vstack_alloc,
	};

	return allocf[lifetime](sim, sz, align);
}

int sim_is_frame_owned(struct sim *sim, void *p){
	// Note: debug only, see comment in arena.c:arena_contains
	return arena_contains(TOP(sim)->arena, p);
}

unsigned sim_frame_id(struct sim *sim){
	return TOP(sim)->fid;
}

void sim_savepoint(struct sim *sim){
	struct frame *f = TOP(sim);
	assert(!f->saved);

	if(!f->vstack_copy)
		f->vstack_copy = arena_alloc(sim->static_arena, SIM_VSTACK_SIZE, alignof(sim->vstack));

	dv("[%u] @ %u -- savepoint %p -> %p (%zu bytes)\n", sim->depth, f->fid, sim->vstack,
			f->vstack_copy, f->vstack_ptr);

	memcpy(f->vstack_copy, sim->vstack, f->vstack_ptr);
	f->saved = 1;
}

void sim_restore(struct sim *sim){
	struct frame *f = TOP(sim);
	assert(f->saved);

	dv("[%u] @ %u -- restore vstack %p -> %p (%zu bytes)\n", sim->depth, f->fid, f->vstack_copy,
			sim->vstack, f->vstack_ptr);

	memcpy(sim->vstack, f->vstack_copy, f->vstack_ptr);
}

void sim_enter(struct sim *sim){
	// TODO error handling
	assert(sim->depth+1 < SIM_MAX_DEPTH);
	sim->depth++;
	dv("==== [%u] enter frame @ %u ====\n", sim->depth, sim->next_fid);
	TOP(sim)->vstack_ptr = PREV(sim)->vstack_ptr;
	f_enter(TOP(sim), sim->next_fid++);
}

void sim_exit(struct sim *sim){
	assert(sim->depth > 0);
	struct frame *f = TOP(sim);
	f_exit(f);
	dv("---- [%u] exit frame @ %u ----\n", sim->depth, f->fid);
	sim->depth--;
}

// Note: after calling this function, the only sim calls to this frame allowed are:
// * sim_take_next_branch()
// * sim_next_branch()
// * sim_exit()
void sim_branch(struct sim *sim, size_t n, sim_branchid *branches){
	// TODO filter branches here when replaying and check the actual number of branches
	// that will be taken in the next condition
	f_branch(TOP(sim), n, branches);

	if(n > 1)
		sim_savepoint(sim);

	dv("[%u] @ %u -- branch point -> %zu choices\n", sim->depth, TOP(sim)->fid, n);
}

// Note: if this function returns true then it enters a frame!
// It must be exited with sim_exit()
bool sim_next_branch(struct sim *sim){
	struct frame *f = TOP(sim);

	// TODO: if recording, remember the branch id and pass it to next frame
	if(!f_next_branch(f))
		return false;

	if(f->dirty)
		sim_restore(sim);

	f->dirty = 1;
	sim_enter(sim);

	return true;
}

static void init_frame(struct sim *sim){
	sim->next_fid = 1;
	sim->depth = 0;
	TOP(sim)->vstack_ptr = 0;
	dv("==== [%u] enter root frame @ %u ====\n", sim->depth, sim->next_fid);
	f_enter(TOP(sim), sim->next_fid++);
}

static void destroy_stack(struct sim *sim){
	for(int i=0;i<SIM_MAX_DEPTH;i++){
		if(sim->fstack[i].init)
			f_destroy(&sim->fstack[i]);
	}
}

static void f_init(struct frame *f){
	assert(!f->init);
	f->init = 1;
	f->arena = arena_create(SIM_ARENA_SIZE);
	f->vstack_copy = NULL;
}

static void f_destroy(struct frame *f){
	assert(f->init);
	arena_destroy(f->arena);
}

static void f_enter(struct frame *f, unsigned fid){
	assert(!f->inside);
	f->fid = fid;
	f->inside = 1;
	f->saved = 0;
	f->dirty = 0;
	f->branches = NULL;

	if(!f->init)
		f_init(f);

	arena_reset(f->arena);
}

static size_t f_salloc(struct frame *f, size_t sz, size_t align){
	assert(f->inside && !f->saved);

	size_t p = ALIGN(f->vstack_ptr, align);
	f->vstack_ptr = p + sz;
	assert(f->vstack_ptr < SIM_VSTACK_SIZE);
	return p;
}

static bool f_next_branch(struct frame *f){
	assert(f->inside && f->branches);

	struct branchinfo *b = f->branches;
	if(b->next < b->nb){
		b->next++;
		return true;
	}

	return false;
}

static void f_branch(struct frame *f, size_t n, sim_branchid *ids){
	assert(f->inside && !f->branches);

	// save the ids even though they aren't currently used
	// these will be used when recording is implemented
	f->branches = f_alloc(f, sizeof(*f->branches) + n*sizeof(sim_branchid), alignof(*f->branches));
	f->branches->nb = n;
	f->branches->next = 0;
	memcpy(f->branches->ids, ids, n*sizeof(sim_branchid));
}

static void f_exit(struct frame *f){
	assert(f->inside);
	f->inside = 0;
}

static void *f_alloc(struct frame *f, size_t size, size_t align){
	assert(f->inside);
	return arena_alloc(f->arena, size, align);
}
