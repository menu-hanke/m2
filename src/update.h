#pragma once

#include "sim.h"
#include "fhk.h"
#include "lex.h"
#include "exec.h"
#include "list.h"

typedef struct ufhk ufhk;
typedef struct uset uset;

ufhk *ufhk_create(struct lex *lex);
void ufhk_destroy(ufhk *u);

void ufhk_set_var(ufhk *u, lexid varid, struct fhk_var *x);
// void ufhk_set_virtual
void ufhk_set_model(ufhk *u, const char *name, ex_func *f, struct fhk_model *m);
void ufhk_set_graph(ufhk *u, struct fhk_graph *G);

int ufhk_update(ufhk *u, uset *s, sim *sim);
int ufhk_update_slice(ufhk *u, uset *s, sim_slice *slice);

uset *uset_create(ufhk *u, lexid objid, size_t nvars, lexid *vars);
void uset_destroy(uset *s);
