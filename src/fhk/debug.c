#include "fhk.h"
#include "graph.h"
#include "def.h"

#include <stdbool.h>

void fhk_set_dsym(struct fhk_graph *G, const char **v_names, const char **m_names){
#ifdef FHK_DEBUG
	G->dsym.v_names = v_names;
	G->dsym.m_names = m_names;
#else
	(void)G;
	(void)v_names;
	(void)m_names;
#endif
}

bool fhk_is_debug(){
#if FHK_DEBUG
	return true;
#else
	return false;
#endif
}

#ifdef FHK_DEBUG

#include <stdio.h>

const char *fhk_Dvar(struct fhk_graph *G, xidx vi){
	static char buf[32];

	if(G->dsym.v_names)
		return G->dsym.v_names[vi];

	sprintf(buf, "var<%zu>", vi);
	return buf;
}

const char *fhk_Dmodel(struct fhk_graph *G, xidx mi){
	static char buf[32];

	if(G->dsym.m_names)
		return G->dsym.m_names[mi];

	sprintf(buf, "model<%zu>", mi);
	return buf;
}

#endif
