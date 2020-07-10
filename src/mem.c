#include "mem.h"
#include "def.h"

#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <stdalign.h>
#include <sys/mman.h>

struct chunk {
	struct region r;
	struct chunk *prev, *next;
};

struct arena {
	struct chunk *first;
	struct chunk *chunk;
};

struct arena_ptr {
	struct chunk *chunk;
	void *mem;
};

static struct chunk *alloc_chunk(size_t size);
static void *bump_next_chunk(struct arena *arena, size_t size, size_t align);

void *mmap_probe_region(size_t size){
	// mmap a suitable region to use for simulation memory.
	// most importantly, try to stay away from luajit's memory range (lower 2GB).
	// in debug mode, look for an address that is easy to identify in a debugger

	// TODO: test if MADV_HUGEPAGE is a good idea here

	for(uintptr_t hint=0x100000000; hint<0x100000000000; hint+=0x100000000){
		void *p = mmap((void *)hint, size, PROT_READ|PROT_WRITE,
				MAP_PRIVATE|MAP_ANONYMOUS|MAP_NORESERVE, -1, 0);

		if(p == MAP_FAILED)
			return NULL;

#ifdef DEBUG
		if(p == (void*)hint)
			return p;
#else
		if(((uintptr_t)p) >> 31)
			return p;
#endif

		munmap(p, size);
	}

#ifdef DEBUG
	// didn't find a nice address, just take something
	void *p = mmap(NULL, size, PROT_READ|PROT_WRITE, MAP_PRIVATE|MAP_ANONYMOUS|MAP_NORESERVE, -1, 0);
	if(p != MAP_FAILED)
		return p;
#endif

	return NULL;
}

void *region_alloc(struct region *region, size_t sz, size_t align){
	uintptr_t p = ALIGN((uintptr_t) region->ptr, align);
	uintptr_t end = p + sz;

	if(UNLIKELY(end >= region->end)){
		dv("region[%p-%p] out of mem (request %ld)\n",
				region->mem, (void*)region->end, sz);
		return NULL;
	}

	region->ptr = (void *) end;
	return (void *) p;
}

// TODO: windows doesn't have mprotect

// Note: this will only work with regions that consist of pages
#define PROTECT(region, prot) mprotect((region), REGION_SIZE(region), (prot))

int region_rw(struct region *region){
	return PROTECT(region, PROT_READ|PROT_WRITE);
}

int region_ro(struct region *region){
	return PROTECT(region, PROT_READ);
}

struct arena *arena_create(size_t size){
	struct arena *ret = malloc(sizeof(*ret));
	struct chunk *chunk = alloc_chunk(size);
	chunk->prev = NULL;
	chunk->next = NULL;
	ret->chunk = chunk;
	ret->first = chunk;
	return ret;
}

void arena_destroy(struct arena *arena){
	struct chunk *chunk = arena->first;

	while(chunk){
		struct chunk *next = chunk->next;
		free(chunk);
		chunk = next;
	}

	free(arena);
}

void *arena_alloc(struct arena *arena, size_t size, size_t align){
	void *ret = region_alloc(&arena->chunk->r, size, align);

	if(LIKELY(ret))
		return ret;

	return bump_next_chunk(arena, size, align);
}

void *arena_malloc(struct arena *arena, size_t size){
	return arena_alloc(arena, size, alignof(max_align_t));
}

void arena_reset(struct arena *arena){
	arena->chunk = arena->first;
	REGION_RESET(&arena->chunk->r);
}

struct arena_ptr *arena_save(struct arena *arena){
	struct chunk *chunk = arena->chunk;
	void *mem = chunk->r.mem;
	struct arena_ptr *ret = arena_alloc(arena, sizeof(*ret), alignof(*ret));
	ret->chunk = chunk;
	ret->mem = mem;
	return ret;
}

void arena_restore(struct arena *arena, struct arena_ptr *to){
	arena->chunk = to->chunk;
	arena->chunk->r.mem = to->mem;
}

static struct chunk *alloc_chunk(size_t size){
	struct chunk *ret = malloc(size + sizeof(*ret));
	REGION_INIT(&ret->r, &ret[1], size);
	return ret;
}

static void *bump_next_chunk(struct arena *arena, size_t size, size_t align){
	struct chunk *c = arena->chunk;

	while(c->next){
		// find a preallocated chunk that fits?
		c = c->next;
		REGION_RESET(&c->r);
		void *ret = region_alloc(&c->r, size, align);
		if(ret){
			arena->chunk = c;
			return ret;
		}
	}

	// make sure it fits
	size_t newsz = REGION_SIZE(&c->r) * 2;
	while(newsz < size+align-1)
		newsz *= 2;

	struct chunk *next = alloc_chunk(newsz);
	c->next = next;
	next->prev = c;
	next->next = NULL;
	arena->chunk = next;

	return region_alloc(&next->r, size, align);
}
