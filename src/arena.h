#pragma once

#include <stddef.h>

typedef struct arena arena;

arena *arena_create(size_t size);
void arena_destroy(arena *arena);
void arena_reset(arena *arena);
void *arena_alloc(arena *arena, size_t size, size_t align);
void *arena_malloc(arena *arena, size_t size);

#include <stdalign.h>
#define ARENA_SALLOC(a, s) arena_alloc((a), sizeof(s), alignof(s))
