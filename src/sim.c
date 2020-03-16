#include "def.h"
#include "mem.h"
#include "sim.h"

#include <stddef.h>
#include <stdlib.h>
#include <stdalign.h>
#include <stdbool.h>
#include <string.h>
#include <assert.h>
#include <sys/mman.h>

// static, vstack and each frame = SIM_MAX_DEPTH + 2 regions
// 1 extra region is allocated so the mapping can be aligned to SIM_REGION_SIZE.
// this is not strictly necessary, but it makes debugging easier because the owning region
// can be seen directly from the pointer
#define SIM_MAP_SIZE ((SIM_MAX_DEPTH + 3) * SIM_REGION_SIZE)
#define SIM_REGION_MEM(base, reg)\
	((void *)(ALIGN((uintptr_t) (base), SIM_REGION_SIZE) + (reg) * SIM_REGION_SIZE))

// from lowest to highest:
// static frame0 ... frameN vstack
// this makes the question "can I modify this memory?" a single pointer comparison:
//     p >= frame->mem
#define STATIC_REGION    0
#define FRAME_REGION(fp) ((fp) + 1)
#define VSTACK_REGION    (SIM_MAX_DEPTH-1)

struct frame {
	unsigned saved    : 1;
	unsigned dirty    : 1;
	unsigned branched : 1;
	unsigned fid;
	region mem;

	void *vstack_copy;
	void *vstack_ptr;
};

struct sim {
	region stat;
	region vstack;
	void *mapping;
	unsigned next_fid;
	unsigned fp;
	struct frame fstack[SIM_MAX_DEPTH];
};

#define TOP(sim) (&((sim)->fstack[(sim)->fp]))
static void f_enter(struct sim *sim, struct frame *f);

struct sim *sim_create(){
	void *mem = mmap_probe_region(SIM_MAP_SIZE);
	if(!mem)
		return NULL;

	dv("sim memory at: %p (%d frames, %lluM regions -> %lluM mapping)\n",
			mem, SIM_MAX_DEPTH, SIM_REGION_SIZE/(1024*1024), SIM_MAP_SIZE/(1024*1024));

	// "allocate" sim's static region on itself
	// Note: there's no alignment problems here, sim is aligned at least on a page boundary
	struct sim *sim = SIM_REGION_MEM(mem, STATIC_REGION);
	sim->mapping = mem;
	REGION_INIT(&sim->stat, sim, SIM_REGION_SIZE);
	region_alloc(&sim->stat, sizeof(*sim), alignof(*sim));

	REGION_INIT(&sim->vstack, SIM_REGION_MEM(mem, VSTACK_REGION), SIM_REGION_SIZE);

	for(unsigned i=0;i<SIM_MAX_DEPTH;i++)
		REGION_INIT(&sim->fstack[i].mem, SIM_REGION_MEM(mem, FRAME_REGION(i)), SIM_REGION_SIZE);

	sim->next_fid = 1;
	sim->fp = 0;
	f_enter(sim, TOP(sim));

	return sim;
}

void sim_destroy(struct sim *sim){
	munmap(sim->mapping, SIM_MAP_SIZE);
}

void *sim_alloc(struct sim *sim, size_t sz, size_t align, int lifetime){
	region *mem;

	switch(lifetime){
		case SIM_STATIC: mem = &sim->stat; break;
		case SIM_FRAME:  mem = &TOP(sim)->mem; break;
		case SIM_VSTACK: mem = &sim->vstack; break;
		// TODO: SIM_SCRATCH
		default: return NULL;
	}

	void *p = region_alloc(mem, sz, align);

#ifdef DEBUG
	// Fill it with garbage (NaNs) to help the user detect if they are doing something stupid.
	// It doesn't actually need to be a double array, since garbage is garbage, but NaNs are
	// probably the most useful garbage value since most allocations in simulation code will
	// be double arrays.
	// Notes:
	// (1) this is the only NaN that work for this, other NaNs are used by luajit for tagging
	// (2) this is undefined behavior and breaks strict aliasing, but it's just for debugging
	for(uintptr_t px=ALIGN((uintptr_t)p, 8); px<((uintptr_t)p)+sz; px+=8)
		*((uint64_t *) px) = 0xfff8000000000000;
#endif

	return p;
}

unsigned sim_frame_id(struct sim *sim){
	return TOP(sim)->fid;
}

int sim_enter(struct sim *sim){
	if(UNLIKELY(sim->fp+1 >= SIM_MAX_DEPTH)){
		dv("[%u] @ %u ERR -- stack overflow\n", sim->fp, TOP(sim)->fid);
		return SIM_EFRAME;
	}

#ifdef DEBUG
	region_ro(&TOP(sim)->mem);
#endif

	sim->fp++;

#ifdef DEBUG
	region_rw(&TOP(sim)->mem);
#endif

	f_enter(sim, TOP(sim));

	return SIM_OK;
}

int sim_exit(struct sim *sim){
	if(UNLIKELY(!sim->fp)){
		dv("[%u] @ %u ERR -- attempt to exit root frame\n", sim->fp, TOP(sim)->fid);
		return SIM_EFRAME;
	}

	dv("[%u] @ %u -- exit\n", sim->fp, TOP(sim)->fid);

#ifdef DEBUG
	region_ro(&TOP(sim)->mem);
#endif

	sim->fp--;

#ifdef DEBUG
	region_rw(&TOP(sim)->mem);
#endif

	return SIM_OK;
}

int sim_savepoint(struct sim *sim){
	struct frame *f = TOP(sim);

	if(UNLIKELY(f->saved)){
		dv("[%u] @ %u ERR -- double savepoint\n", sim->fp, f->fid);
		return SIM_ESAVE;
	}

	size_t size = REGION_USED(&sim->vstack);
	f->vstack_ptr = sim->vstack.ptr;
	f->vstack_copy = region_alloc(&f->mem, size, M2_SIMD_ALIGN);

	if(UNLIKELY(!f->vstack_copy))
		return SIM_EALLOC;

	f->saved = 1;
	memcpy(f->vstack_copy, sim->vstack.mem, size);

	dv("[%u] @ %u -- savepoint %p -> %p (%zu bytes)\n", sim->fp, f->fid, sim->vstack.mem,
			f->vstack_copy, size);

	return SIM_OK;
}

int sim_restore(struct sim *sim){
	struct frame *f = TOP(sim);

	if(UNLIKELY(!f->saved)){
		dv("[%u] @ %u ERR -- no savepoint\n", sim->fp, f->fid);
		return SIM_ESAVE;
	}

	sim->vstack.ptr = f->vstack_ptr;
	size_t size = REGION_USED(&sim->vstack);
	memcpy(sim->vstack.mem, f->vstack_copy, size);

	dv("[%u] @ %u -- restore %p -> %p (%zu bytes)\n", sim->fp, f->fid, f->vstack_copy,
			sim->vstack.mem, size);

	return SIM_OK;
}

int sim_branch(struct sim *sim, int hint){
	struct frame *f = TOP(sim);

	if(UNLIKELY(f->branched)){
		dv("[%u] @ %u ERR -- double branch point\n", sim->fp, f->fid);
		return SIM_EBRANCH;
	}

	f->branched = 1;

	// TODO: if replaying, ignore hint and just check how many branches
	if(hint & SIM_MULTIPLE){
		int r;
		if((r = sim_savepoint(sim)))
			return r;
	}

	dv("[%u] @ %u -- branch point\n", sim->fp, f->fid);

	return SIM_OK;
}

int sim_take_branch(struct sim *sim, sim_branchid id){
	// TODO:
	// * if replaying and id is skipped, return SIM_SKIP
	// * if recording, remember id
	(void)id;

	struct frame *f = TOP(sim);

	if(UNLIKELY(!f->branched))
		return SIM_EBRANCH;

	if(f->dirty){
		int r;
		if((r = sim_restore(sim)))
			return r;
	}

	f->dirty = 1;
	sim_enter(sim);

	return SIM_OK;
}

static void f_enter(struct sim *sim, struct frame *f){
	assert(f == TOP(sim));

	f->fid = sim->next_fid++;
	f->saved = 0;
	f->dirty = 0;
	f->branched = 0;
	REGION_RESET(&f->mem);

	dv("[%u] @ %u -- enter\n", sim->fp, f->fid);
}
