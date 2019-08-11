#pragma once

#include "fhk.h"
#include "lex.h"
#include "world.h"

typedef struct ugraph ugraph;
typedef struct u_obj u_obj;
typedef struct u_var u_var;
typedef struct u_env u_env;
typedef struct u_comp u_comp;
typedef struct u_glob u_glob;
typedef struct u_model u_model;
typedef struct uset_header uset;
typedef struct uset_obj uset_obj;
typedef void (*u_solver_cb)(void *udata, struct fhk_graph *G, size_t nv, struct fhk_var **xs);

struct ugraph *u_create(struct fhk_graph *G);
void u_destroy(ugraph *u);

u_obj *u_add_obj(ugraph *u, w_obj *obj, const char *name);
u_var *u_add_var(ugraph *u, u_obj *obj, lexid varid, struct fhk_var *x, const char *name);
u_env *u_add_env(ugraph *u, w_env *env, struct fhk_var *x, const char *name);
// u_glob *u_add_glob(ugraph *u, ???)
u_comp *u_add_comp(ugraph *u, struct fhk_var *x, const char *name);
u_model *u_add_model(ugraph *u, ex_func *f, struct fhk_model *m, const char *name);

uset_obj *uset_create_obj(ugraph *u, u_obj *obj, world *world, size_t nv, lexid *varids);
void uset_update_obj(ugraph *u, uset_obj *s);
void uset_destroy_obj(uset_obj *s);

void uset_init_flag(uset *s, int xidx, fhk_vbmap flag);
void uset_solver_cb(uset *s, u_solver_cb cb, void *udata);
