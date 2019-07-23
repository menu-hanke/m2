/* simple bump allocator */

#include "def.h"

#include <stdlib.h>
#include <stdint.h>
#include <stddef.h>
#include <stdalign.h>

struct chunk {
	struct chunk *prev, *next;
	void *ptr;
	size_t size;
	char data[];
};

struct arena {
	struct chunk *first;
	struct chunk *chunk;
};

static struct chunk *alloc_chunk(size_t size);
static void *bump(struct chunk *c, size_t size, size_t align);
static void *bump_next_chunk(struct arena *arena, size_t size, size_t align);

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

void arena_reset(struct arena *arena){
	for(struct chunk *c=arena->first; c; c=c->next)
		c->ptr = c->data;

	arena->chunk = arena->first;
}

void *arena_alloc(struct arena *arena, size_t size, size_t align){
	void *ret = bump(arena->chunk, size, align);

	if(ret)
		return ret;

	return bump_next_chunk(arena, size, align);
}

void *arena_malloc(struct arena *arena, size_t size){
	return arena_alloc(arena, size, alignof(max_align_t));
}

static struct chunk *alloc_chunk(size_t size){
	// TODO: this doesn't have to be backed by malloc, support other allocators if needed
	struct chunk *ret = malloc(sizeof(*ret) + size);
	ret->size = size;
	ret->ptr = ret->data;
	dv("alloc chunk size=%zu\n", size);
	return ret;
}

static void *bump(struct chunk *c, size_t size, size_t align){
	uintptr_t p = ALIGN((uintptr_t) c->ptr, align);
	p += size;

	if(p >= ((uintptr_t)(c->data + c->size))){
		dv("alloc doesn't fit in chunk: size=%zu align=%zu chunk=%p ptr=%p\n",
				size, align, c->data, c->ptr);
		return NULL;
	}

	void *ret = c->ptr;
	c->ptr = (void *) p;
	return ret;
}

static void *bump_next_chunk(struct arena *arena, size_t size, size_t align){
	struct chunk *c = arena->chunk;

	while(c->next){
		// find a preallocated chunk that fits?
		c = c->next;
		void *ret = bump(c, size, align);
		if(ret){
			arena->chunk = c;
			return ret;
		}
	}

	// double next chunk size to reduce mallocs
	size_t newsz = c->size * 2;

	// make sure it fits
	while(newsz < size+align-1)
		newsz *= 2;

	struct chunk *next = alloc_chunk(newsz);
	next->prev = c;
	next->next = NULL;
	arena->chunk = next;

	return bump(next, size, align);
}
