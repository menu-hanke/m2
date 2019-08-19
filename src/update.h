#pragma once

#include "fhk.h"
#include "bitmap.h"
#include "lex.h"
#include "world.h"

typedef struct ugraph ugraph;
typedef struct u_obj u_obj;
typedef struct u_var u_var;
typedef struct u_env u_env;
typedef struct u_comp u_comp;
typedef struct u_global u_global;
typedef struct u_model u_model;
typedef void (*u_solver_cb)(void *udata, struct fhk_graph *G, size_t nv, struct fhk_var **xs);

ugraph *u_create(struct fhk_graph *G);
void u_destroy(ugraph *u);

u_obj *u_add_obj(ugraph *u, w_obj *obj, const char *name);
u_var *u_add_var(ugraph *u, u_obj *obj, lexid varid, struct fhk_var *x, const char *name);
u_env *u_add_env(ugraph *u, w_env *env, struct fhk_var *x, const char *name);
u_global *u_add_global(ugraph *u, w_global *glob, struct fhk_var *x, const char *name);
u_comp *u_add_comp(ugraph *u, struct fhk_var *x, const char *name);
u_model *u_add_model(ugraph *u, ex_func *f, struct fhk_model *m, const char *name);

void u_init_given_obj(bm8 *init_v, u_obj *obj);
void u_init_given_envs(bm8 *init_v, ugraph *u);
void u_init_given_globals(bm8 *init_v, ugraph *u);
void u_init_solve(bm8 *init_v, struct fhk_var *y);
void u_graph_init(ugraph *u, bm8 *init_v);

void u_mark_obj(bm8 *vmask, u_obj *obj);
void u_mark_envs_z(bm8 *vmask, ugraph *u, size_t order);
void u_reset_mark(ugraph *u, bm8 *vmask, bm8 *mmask);
void u_graph_reset(ugraph *u, bm8 *reset_v, bm8 *reset_m);

void u_bind_obj(u_obj *obj, w_objref *ref);
void u_unbind_obj(u_obj *obj);
void u_bind_pos(ugraph *u, gridpos pos);
void u_unbind_pos(ugraph *u);

void u_solve_vec(ugraph *u, u_obj *obj, bm8 *reset_v, bm8 *reset_m, w_objvec *v,
		size_t nv, struct fhk_var **xs, void **res, type *types);
void u_update_vec(ugraph *u, u_obj *obj, world *w, bm8 *reset_v, bm8 *reset_m, w_objvec *v,
		size_t nv, struct fhk_var **xs, lexid *vars);
