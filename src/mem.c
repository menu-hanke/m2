#include "mem.h"
#include "def.h"
#include "conf.h"

#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <stdalign.h>

static void *bump(uintptr_t *p, size_t size, size_t align, uintptr_t end);

#if M2_WINDOWS
#include <windows.h>

void *vm_map_probe(size_t size){
	// TODO?: this should probe a >2gb address?
	return VirtualAlloc(0, size, MEM_RESERVE|MEM_COMMIT, PAGE_READWRITE);
}

void vm_unmap(void *p, size_t size){
	(void)size;
	VirtualFree(p, 0, MEM_RELEASE);
}

// TODO: VirtualProtect

void reg_ro(struct region *r){
	(void)r;
}

void reg_rw(struct region *r){
	(void)r;
}

#else

#include <sys/mman.h>

static void *mmap_probe(void *hint, size_t size, int tries){
	void *p = mmap(hint, size, PROT_READ|PROT_WRITE,
			MAP_PRIVATE|MAP_ANONYMOUS|MAP_NORESERVE, -1, 0);

	if(p == MAP_FAILED)
		return NULL;

	if(((uintptr_t) p) > VM_MAP_ABOVE)
		return p;

	if(tries >= VM_PROBE_RETRIES)
		return NULL;

	void *r = mmap_probe(hint + VM_MAP_ABOVE, size, tries+1);
	munmap(p, size);
	return r;
}

void *vm_map_probe(size_t size){
	return mmap_probe((void*)VM_MAP_ABOVE, size, 0);
}

void vm_unmap(void *p, size_t size){
	munmap(p, size);
}

void reg_ro(struct region *r){
	mprotect((void *)r->mem, r->end-r->mem, PROT_READ);
}

void reg_rw(struct region *r){
	mprotect((void *)r->mem, r->end-r->mem, PROT_READ|PROT_WRITE);
}

#endif

void reg_init(struct region *r, void *mem, size_t size){
	r->mem = (uintptr_t) mem;
	r->ptr = r->mem;
	r->end = r->mem + size;
}

void *reg_alloc(struct region *r, size_t sz, size_t align){
	return bump(&r->ptr, sz, align, r->end);
}

struct arena *arena_create(size_t size){
	static_assert(sizeof(struct arena) % alignof(struct chunk) == 0);

	void *p = malloc(sizeof(struct arena) + sizeof(struct chunk) + size);
	struct arena *arena = p;
	arena->chunk = p + sizeof(struct arena);
	arena->chunk->prev = NULL;
	arena->chunk->next = NULL;
	arena->chunk->end = (uintptr_t)arena->chunk->mem + size;
	arena->mem = (uintptr_t) arena->chunk->mem;
	arena->end = arena->chunk->end;

	return arena;
}

void arena_destroy(struct arena *arena){
	struct chunk *chunk = arena->chunk;
	while(chunk->next)
		chunk = chunk->next;

	// this won't intentionally free the first chunk because it's allocated with the arena
	while(chunk->prev){
		struct chunk *prev = chunk->prev;
		free(chunk);
		chunk = prev;
	}

#ifdef DEBUG
	arena->chunk = NULL;
#endif

	// first chunk is freed here
	free(arena);
}

void *arena_alloc(struct arena *arena, size_t size, size_t align){
	void *p = bump(&arena->mem, size, align, arena->end);

	if(LIKELY(p))
		return p;

	dv("allocation %zu(%zu) overflowed chunk @ %p->%p [%p]\n", size, align,
			arena->chunk->mem, (void*)arena->chunk->end, (void*)arena->mem);

	// find a preallocated chunk?
	while(arena->chunk->next){
		arena->chunk = arena->chunk->next;
		uintptr_t mem = (uintptr_t) arena->chunk->mem;
		p = bump(&mem, size, align, arena->chunk->end);

		if(LIKELY(p)){
			arena->mem = mem;
			arena->end = arena->chunk->end;
			return p;
		}
	}

	// need to malloc a new one
	size_t newsz = (size_t) (arena->chunk->end - (uintptr_t)arena->chunk->mem) * 2;
	while(newsz < size+align-1)
		newsz *= 2;

	struct chunk *c = malloc(sizeof(*c) + newsz);
	c->end = (uintptr_t)c->mem + newsz;
	c->prev = arena->chunk;
	arena->chunk->next = c;
	c->next = NULL;
	arena->chunk = c;

	uintptr_t mem = (uintptr_t) c->mem;
	p = bump(&mem, size, align, c->end);
	assert(p);

	arena->mem = mem;
	arena->end = c->end;
	return p;
}

void *arena_malloc(struct arena *arena, size_t size){
	return arena_alloc(arena, size, alignof(max_align_t));
}

void arena_reset(struct arena *arena){
	while(arena->chunk->prev)
		arena->chunk = arena->chunk->prev;

	arena->mem = (uintptr_t)arena->chunk->mem;
	arena->end = arena->chunk->end;
}

static void *bump(uintptr_t *p, size_t size, size_t align, uintptr_t end){
	uintptr_t r = ALIGN(*p, align);

	if(LIKELY(r+size < end)){
		*p = r + size;
		return (void*)r;
	}

	return NULL;
}
