#pragma once

#include <stdint.h>
#include <stddef.h>

typedef struct region {
	void *mem;
	void *ptr;
	uintptr_t end;
} region;

typedef struct arena arena;

#define REGION_RESET(r)    (r)->ptr = (r)->mem
#define REGION_INIT(r,m,s)\
	do { (r)->ptr = (r)->mem = (m); (r)->end = ((uintptr_t)(r)->mem) + (s); } while(0)
#define REGION_SIZE(r)     ((r)->end - ((uintptr_t)(r)->mem))
#define REGION_USED(r)     (((uintptr_t)(r)->ptr) - ((uintptr_t)(r)->mem))

void *mmap_probe_region(size_t size);

void *region_alloc(struct region *region, size_t sz, size_t align) __attribute__((malloc));
int region_rw(struct region *region);
int region_ro(struct region *region);

struct arena *arena_create(size_t size);
void arena_destroy(struct arena *arena);
void *arena_alloc(struct arena *arena, size_t size, size_t align);
void *arena_malloc(struct arena *arena, size_t size);
void arena_reset(struct arena *arena);
