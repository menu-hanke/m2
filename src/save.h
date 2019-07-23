#pragma once

#include "arena.h"
#include <stddef.h>

typedef struct save save;

save *save_create(arena *arena);
void save_copy(save *s, void *p, size_t sz);
void save_rollback(save *s);
