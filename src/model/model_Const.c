/* model that always returns a constant value - this is mainly useful for testing */

#include "model_Const.h"
#include "../def.h"

#include <stdlib.h>
#include <stddef.h>
#include <stdalign.h>
#include <stdbool.h>
#include <string.h>

struct mod_Const {
	struct {
		size_t size;
		void *mem;
	} bufs[0];
};

uint64_t mod_Const_types(){
	return ~0ULL;
}

struct mod_Const *mod_Const_create(size_t num, size_t *nr, void **rv){
	size_t off = sizeof(*((struct mod_Const *) 0)->bufs) * num;
	size_t na = 0;
	for(size_t i=0;i<num;i++)
		na += nr[i];

	struct mod_Const *M = malloc(na + off);

	void *mem = ((void *) M) + off;
	for(size_t i=0;i<num;i++){
		M->bufs[i].size = nr[i];
		M->bufs[i].mem = mem;
		memcpy(mem, rv[i], nr[i]);
		mem += nr[i];
	}

	return M;
}

bool mod_Const_call(struct mod_Const *M, mcall_s *mc){
	mcall_edge *e = mc->edges + mc->np;
	for(size_t i=0;i<mc->nr;i++,e++)
		memcpy(e->p, M->bufs[i].mem, M->bufs[i].size);
	return true;
}

void mod_Const_destroy(struct mod_Const *M){
	free(M);
}
