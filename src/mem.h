#pragma once

#include "def.h"

#include <stddef.h>
#include <stdint.h>

typedef struct region {
	uintptr_t ptr;
	uintptr_t end;
	uintptr_t mem;
} region;

typedef struct chunk {
	struct chunk *prev, *next;
	uintptr_t end;
	char mem[];
} chunk;

typedef struct arena {
	struct chunk *chunk;
	uintptr_t mem, end;
} arena;

void *vm_map_probe(size_t size);
void vm_unmap(void *p, size_t size);

#define REG_RESET(r) do { (r)->ptr = (r)->mem; } while(0)
void reg_init(region *r, void *mem, size_t size);
void *reg_alloc(region *r, size_t sz, size_t align) __attribute__((malloc));
void reg_ro(region *r);
void reg_rw(region *r);

arena *arena_create(size_t size);
void arena_destroy(arena *arena);
void *arena_alloc(arena *arena, size_t size, size_t align) __attribute__((malloc));
void *arena_malloc(arena *arena, size_t size) __attribute__((malloc));
void arena_reset(arena *arena);
