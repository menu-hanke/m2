/* simple bump allocator */

#include "def.h"
#include "arena.h"

#include <stdlib.h>
#include <stdint.h>
#include <stddef.h>
#include <stdalign.h>
#include <stdarg.h>
#include <stdio.h>
#include <assert.h>
#include <string.h>

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
static void reset_chunk(struct chunk *c);
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
	arena->chunk = arena->first;
	reset_chunk(arena->chunk);
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

char *arena_salloc(struct arena *arena, size_t size){
	return arena_alloc(arena, size, 1);
}

void arena_save(struct arena *arena, arena_ptr *p){
	p->chunk = arena->chunk;
	p->ptr = arena->chunk->ptr;
}

void arena_restore(struct arena *arena, arena_ptr *p){
	arena->chunk = p->chunk;
	arena->chunk->ptr = p->ptr;
}

int arena_contains(struct arena *arena, void *p){
	// Note: this is undefined behavior and only intended for debugging, don't use this
	// for any actual logic
	uintptr_t ip = (uintptr_t) p;
	for(struct chunk *c=arena->first; c; c=c->next){
		uintptr_t cp = (uintptr_t) c->data;
		if(ip >= cp && ip < cp+c->size)
			return 1;
	}

	return 0;
}

char *arena_vasprintf(struct arena *arena, const char *fmt, va_list arg){
	va_list v;
	va_copy(v, arg);
	int size = vsnprintf(NULL, 0, fmt, v);
	va_end(v);
	if(size < 0)
		return NULL;
	char *ret = arena_salloc(arena, size+1);
	vsprintf(ret, fmt, arg);
	return ret;
}

char *arena_asprintf(struct arena *arena, const char *fmt, ...){
	va_list arg;
	va_start(arg, fmt);
	char *ret = arena_vasprintf(arena, fmt, arg);
	va_end(arg);
	return ret;
}

char *arena_strcpy(struct arena *arena, const char *src){
	char *ret = arena_salloc(arena, strlen(src)+1);
	strcpy(ret, src);
	return ret;
}

static struct chunk *alloc_chunk(size_t size){
	// TODO: this doesn't have to be backed by malloc, support other allocators if needed
	struct chunk *ret = malloc(sizeof(*ret) + size);
	ret->size = size;
	reset_chunk(ret);
	dv("alloc chunk size=%zu\n", size);
	return ret;
}

static void reset_chunk(struct chunk *c){
	c->ptr = c->data;
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
		reset_chunk(c);
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
	assert(!c->next);
	c->next = next;
	next->prev = c;
	next->next = NULL;
	arena->chunk = next;

	return bump(next, size, align);
}
