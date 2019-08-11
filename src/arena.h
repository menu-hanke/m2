#pragma once

#include <stddef.h>
#include <stdarg.h>

typedef struct arena arena;

typedef struct arena_ptr {
	void *chunk;
	void *ptr;
} arena_ptr;

arena *arena_create(size_t size);
void arena_destroy(arena *arena);
void arena_reset(arena *arena);

void *arena_alloc(arena *arena, size_t size, size_t align);
void *arena_malloc(arena *arena, size_t size);
char *arena_salloc(arena *arena, size_t size);

void arena_save(arena *arena, arena_ptr *p);
void arena_restore(arena *arena, arena_ptr *p);

int arena_contains(arena *arena, void *p);
char *arena_vasprintf(arena *arena, const char *fmt, va_list arg);
char *arena_asprintf(arena *arena, const char *fmt, ...);
char *arena_strcpy(arena *arena, const char *src);
