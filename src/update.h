#pragma once

#include "fhk.h"
#include "lex.h"

typedef struct ugraph ugraph;
typedef struct uset uset;
typedef void (*u_solver_cb)(void *udata, struct fhk_graph *G, size_t nv, struct fhk_var **xs);

ugraph *u_create(sim *sim, struct lex *lex, struct fhk_graph *G);
void u_destroy(ugraph *u);

void u_link_var(ugraph *u, struct fhk_var *x, struct obj_def *obj, struct var_def *var);
void u_link_env(ugraph *u, struct fhk_var *x, struct env_def *env);
void u_link_computed(ugraph *u, struct fhk_var *x, const char *name);
void u_link_model(ugraph *u, struct fhk_model *m, const char *name, ex_func *f);

uset *uset_create_vars(ugraph *u, lexid objid, size_t nv, lexid *varids);
uset *uset_create_envs(ugraph *u, size_t nv, lexid *envids);
void uset_init_flag(uset *s, int xidx, fhk_vbmap flag);
void uset_solver_cb(uset *s, u_solver_cb, void *udata);
void uset_destroy(uset *s);

void uset_update(ugraph *u, uset *s);
