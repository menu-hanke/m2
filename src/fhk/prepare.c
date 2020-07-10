#include "fhk.h"
#include "graph.h"
#include "def.h"

#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>

static void g_compute_flags(struct fhk_graph *G);
static void g_reorder_edges(struct fhk_graph *G);
static void g_compute_ng(struct fhk_graph *G);

void fhk_prepare(struct fhk_graph *G){
	// XXX this probably doesn't belong here, rather make a graph.c with graph algorithms
	g_compute_flags(G);
	g_reorder_edges(G);
	g_compute_ng(G);
}

static void g_compute_flags(struct fhk_graph *G){
}

