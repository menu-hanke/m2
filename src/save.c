#include "arena.h"

#include <stddef.h>
#include <string.h>

// Note: this currently assumes arena but the implementation can work with
// any kind of allocator

struct savepoint {
	struct savepoint *next;
	void *p;
	size_t size;
	char data[];
};

struct save {
	arena *arena;
	struct savepoint *first;
	struct savepoint **tail_ptr;
};

struct save *save_create(arena *arena){
	struct save *s = arena_malloc(arena, sizeof(*s));
	s->arena = arena;
	s->first = NULL;
	s->tail_ptr = &s->first;
	return s;
}

void save_copy(struct save *s, void *p, size_t sz){
	struct savepoint *sp = arena_malloc(s->arena, sizeof(*sp) + sz);
	sp->p = p;
	sp->size = sz;
	sp->next = NULL;
	*s->tail_ptr = sp;
	s->tail_ptr = &sp->next;
	memcpy(sp->data, p, sz);
}

void save_rollback(struct save *s){
	for(struct savepoint *sp=s->first; sp; sp=sp->next)
		memcpy(sp->p, sp->data, sp->size);
}
