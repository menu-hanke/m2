#include "fhk.h"
#include "def.h"

#include <stdbool.h>

void fhk_set_dsym(struct fhk_graph *G, const char **dsym){
#if FHK_DEBUG
	G->dsym = dsym;
#else
	(void)G;
	(void)dsym;
#endif
}

bool fhk_is_debug(){
#if FHK_DEBUG
	return true;
#else
	return false;
#endif
}

#if FHK_DEBUG

#include <stdio.h>

// debug symbol for idx, DO NOT store the return value, it's an internal ring buffer.
// only use this for debug printing. the ring buffer is to allow using multiple debug syms
// in the same print call.
const char *fhk_dsym(struct fhk_graph *G, xidx idx){
	static char rbuf[4][32];
	static int pos = 0;

	if(idx >= -G->nm && idx < G->nx && G->dsym && G->dsym[idx])
		return G->dsym[idx];

	char *buf = rbuf[pos];
	pos = (pos + 1) % 4;

	const char *fmt = (idx < -G->nm) ? "(OOB model: %zd)"
		            : (idx < 0)      ? "model[%zd]"
					: (idx < G->nv)  ? "var[%zd]"
					: (idx < G->nx)  ? "shadow[%zd]"
					:                  "(OOB xnode: %zd)";

	sprintf(buf, fmt, idx);
	return buf;
}

#endif
