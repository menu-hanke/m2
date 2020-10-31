#include "def.h"
#include "mem.h"
#include "sim.h"
#include "conf.h"

#include <stddef.h>
#include <stdlib.h>
#include <stdalign.h>
#include <stdint.h>
#include <assert.h>

// reserve vstack+static+nframe frames + 1 extra for alignment
#define MAPPING_SIZE(n,r) (((size_t)(r)) * ((size_t)(n) + 3))

typedef struct {
	char _[SIM_SAVEPOINT_BLOCKSIZE];
} block __attribute__((aligned(SIM_SAVEPOINT_BLOCKSIZE)));

struct frame {
	unsigned has_savepoint    : 1;
	unsigned has_branchpoint  : 1;

	uint32_t fid;
	region mem;

	// savepoint data, only touch this when has_savepoint=1
	void *vstack_copy;
	void *vstack_ptr;
};

struct sim {
	region stat;
	region vstack;
	void *mapping;
	uint32_t nframe;
	uint32_t rsize;
	uint32_t next_fid;
	uint32_t fp;
	struct frame fstack[];
};

#define TOP(sim) (&((sim)->fstack[(sim)->fp]))
static void f_enter(struct sim *sim, struct frame *f);
static void blockcpy(void *restrict dst, void *restrict src, size_t size);

struct sim *sim_create(uint32_t nframe, uint32_t rsize){
	// rsize must be a power of 2
	if(rsize & (rsize-1))
		return NULL;

	size_t mapsz = MAPPING_SIZE(nframe, rsize);
	void *mem = vm_map_probe(mapsz);
	if(!mem)
		return NULL;

	void *mem_align = ALIGN(mem, rsize);
	dv("sim memory at: %p (map: %p) -- %d frames, %uM regions -> %zuM mapping\n",
			mem_align, mem, nframe, rsize/(1024*1024), mapsz/(1024*1024));

	// allocate regions:
	// 0           -> static
	// [1, nframe] -> frame
	// nframe+1    -> vstack
	struct sim *sim = mem_align;
	sim->mapping = mem;
	reg_init(&sim->stat, mem_align, rsize);
	reg_alloc(&sim->stat, sizeof(*sim) + nframe*sizeof(*sim->fstack), alignof(*sim));

	reg_init(&sim->vstack, mem_align + (size_t)rsize*(nframe+1), rsize);

	for(uint32_t i=0;i<nframe;i++)
		reg_init(&sim->fstack[i].mem, mem_align + (size_t)rsize*(i+1), rsize);

	sim->nframe = nframe;
	sim->rsize = rsize;
	sim->next_fid = 1;
	sim->fp = 0;
	f_enter(sim, TOP(sim));

	return sim;
}

void sim_destroy(struct sim *sim){
	vm_unmap(sim->mapping, MAPPING_SIZE(sim->nframe, sim->rsize));
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

	void *p = reg_alloc(mem, sz, align);

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

uint32_t sim_fp(struct sim *sim){
	return sim->fp;
}

uint32_t sim_frame_id(struct sim *sim){
	return TOP(sim)->fid;
}

int sim_savepoint(struct sim *sim){
	struct frame *f = TOP(sim);
	size_t size = sim->vstack.ptr - sim->vstack.mem;

	// have a reusable savepoint?
	if(UNLIKELY(f->has_savepoint)){
		// old alloc fits?
		// note: sim->vstack.ptr >= f->vstack_ptr
		if(sim->vstack.ptr == (uintptr_t)f->vstack_ptr)
			goto copy;

		// can extend old alloc?
		if(f->mem.ptr == (uintptr_t)f->vstack_copy + ((uintptr_t)f->vstack_ptr - sim->vstack.mem)){
			f->mem.ptr = (uintptr_t) f->vstack_copy + size;
			f->vstack_ptr = (void *) sim->vstack.ptr;
			goto copy;
		}

		dv("[%u] @ %u LEAK %p -- vstack grew %zu -> %zu bytes (savepoint not extendable)\n",
				sim->fp, f->fid, f->vstack_copy,
				(uintptr_t)f->vstack_ptr - sim->vstack.mem, size);
	}

	// both the allocation and region end are aligned at least blocksize, so if the allocation
	// succeeds the remainder of the last block can be copied over without overruning the region
	f->vstack_ptr = (void*)sim->vstack.ptr;
	f->vstack_copy = reg_alloc(&f->mem, size, SIM_SAVEPOINT_BLOCKSIZE);
	if(UNLIKELY(!f->vstack_copy))
		return SIM_EALLOC;

	f->has_savepoint = 1;

copy:
	blockcpy(f->vstack_copy, (void*)sim->vstack.mem, size);

	dv("[%u] @ %u -- savepoint %p -> %p (%zu bytes)\n", sim->fp, f->fid, (void*)sim->vstack.mem,
			f->vstack_copy, size);

	return SIM_OK;
}

int sim_up(struct sim *sim, uint32_t fp){
	if(UNLIKELY(fp > sim->fp)){
		dv("[%u] @ %u ERR -- jump down -> %u\n", sim->fp, TOP(sim)->fid, fp);
		return SIM_EFRAME;
	}

#ifdef DEBUG
	for(uint32_t i=fp+1; i<=sim->fp; i++)
		reg_ro(&sim->fstack[i].mem);
#endif

	dv("[%u->%u] @ %u->%u -- frame jump\n", sim->fp, fp, TOP(sim)->fid, sim->fstack[fp].fid);

	sim->fp = fp;

	return SIM_OK;
}

int sim_reload(struct sim *sim){
	struct frame *f = TOP(sim);

	if(UNLIKELY(!f->has_savepoint)){
		dv("[%u] @ %u ERR -- no savepoint\n", sim->fp, f->fid);
		return SIM_ESAVE;
	}

	sim->vstack.ptr = (uintptr_t)f->vstack_ptr;
	size_t size = sim->vstack.ptr - sim->vstack.mem;
	blockcpy((void*)sim->vstack.mem, f->vstack_copy, size);

	dv("[%u] @ %u -- restore %p -> %p (%zu bytes)\n", sim->fp, f->fid, f->vstack_copy,
			(void*)sim->vstack.mem, size);

	return SIM_OK;
}

int sim_load(struct sim *sim, uint32_t fp){
	int r;
	if((r = sim_up(sim, fp)))
		return r;

	return sim_reload(sim);
}

int sim_enter(struct sim *sim){
	// XXX any reason to call this without a savepoint?
	// if not, add an assertion.

	if(UNLIKELY(sim->fp+1 >= sim->nframe)){
		dv("[%u] @ %u ERR -- stack overflow\n", sim->fp, TOP(sim)->fid);
		return SIM_EFRAME;
	}

	sim->fp++;

#ifdef DEBUG
	reg_rw(&TOP(sim)->mem);
#endif

	f_enter(sim, TOP(sim));

	return SIM_OK;
}

int sim_branch(struct sim *sim, int hint){
	TOP(sim)->has_branchpoint = 1;

	// TODO: if replaying, ignore hint and just check how many branches
	if(hint & SIM_CREATE_SAVEPOINT){
		int r;
		if((r = sim_savepoint(sim)))
			return r;
	}

	dv("[%u] @ %u -- branch point\n", sim->fp, TOP(sim)->fid);

	return SIM_OK;
}

int sim_enter_branch(struct sim *sim, uint32_t fp, int hint){
	if(fp != sim->fp){
		int r;
		if((r = sim_load(sim, fp)))
			return r;
	}

	struct frame *f = TOP(sim);

	if(UNLIKELY(!f->has_branchpoint)){
		dv("[%u] @ %u ERR -- no branch point\n", sim->fp, f->fid);
		return SIM_EBRANCH;
	}

	// TODO: if replaying, the last taken branch from a branchpoint is a tailcall
	if(hint & SIM_TAILCALL){
		f->has_branchpoint = 0;
	}else{
		int r;
		if((r = sim_enter(sim)))
			return r;
	}

	return SIM_OK;
}

static void f_enter(struct sim *sim, struct frame *f){
	assert(f == TOP(sim));

	f->fid = sim->next_fid++;
	f->has_savepoint = 0;
	f->has_branchpoint = 0;
	REG_RESET(&f->mem);

	dv("[%u] @ %u -- enter\n", sim->fp, f->fid);
}

static void blockcpy(void *restrict dst, void *restrict src, size_t size){
	block *a = dst;
	block *b = src;

	for(size_t i=0;i<size;i+=SIM_SAVEPOINT_BLOCKSIZE)
		*a++ = *b++;
}
