#include "arena.h"

#include <stddef.h>
#include <string.h>

// Note: this currently assumes arena but the implementation can work with
// any kind of allocator

struct savepoint {
	struct savepoint *prev;
	void *p;
	size_t size;
	char data[];
};

struct save {
	arena *arena;
	struct savepoint *last;
};

struct save *save_create(arena *arena){
	struct save *s = arena_malloc(arena, sizeof(*s));
	s->arena = arena;
	s->last = NULL;
	return s;
}

void save_copy(struct save *s, void *p, size_t sz){
	struct savepoint *sp = arena_malloc(s->arena, sizeof(*sp) + sz);
	sp->p = p;
	sp->size = sz;
	sp->prev = s->last;
	s->last = sp;
	memcpy(sp->data, p, sz);
}

void save_rollback(struct save *s){
	for(struct savepoint *sp=s->last; sp; sp=sp->prev)
		memcpy(sp->p, sp->data, sp->size);
}
