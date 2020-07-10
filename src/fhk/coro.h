#include <aco.h>
#include <stdint.h>
#include <stdlib.h>

#include "../def.h"

// TODO
// there is no good coroutine library that works for the purpose of fhk.
// the current implementation works around some problems of libaco with some performance penalties.
// in the future this should be replaced with a custom coroutine implementation that:
// * lets user allocate and reuse coroutine objects (important)
// * lets coroutines share a stack without copying (not so important)

// current implementation is a workaround: maintain a cache of coro objects,
// use a custom function to reset them

#define CO_FREE 1
#define CO_MASK ~1

// co         = NULL -> not init
// free (lsb) = 1 -> can be allocated (nonnull co implies lsb = 0 because of alignment)
typedef struct {
	union {
		aco_t *co;
		uintptr_t p;
	};
	fhk_status status;
} fhk_co;

static __thread struct {
	aco_t *main;
	aco_share_stack_t *sstk;
	size_t nc;
	fhk_co *cache;
} fhk_co_s;

static inline void fhk_co_thread_init(){
	if(UNLIKELY(!fhk_co_s.main)){
		aco_runtime_test();
		aco_thread_init(NULL);
		fhk_co_s.main = aco_create(NULL, NULL, 0, NULL, NULL);
		fhk_co_s.sstk = aco_share_stack_new(0);
		fhk_co_s.nc = 0;
		fhk_co_s.cache = NULL;
	}
}

static fhk_co *co_alloc(){
	for(size_t i=0;i<fhk_co_s.nc;i++){
		if(!fhk_co_s.cache[i].co || (fhk_co_s.cache[i].p & CO_FREE))
			return &fhk_co_s.cache[i];
	}

	// this cache will almost never grow so doubling would be a waste
	fhk_co_s.nc++;
	fhk_co_s.cache = realloc(fhk_co_s.cache, fhk_co_s.nc * sizeof(fhk_co));
	fhk_co_s.cache[fhk_co_s.nc-1].co = NULL;
	return &fhk_co_s.cache[fhk_co_s.nc-1];
}

static inline fhk_co *fhk_co_create(void *fp, void *arg){
	fhk_co *fc = co_alloc();

	if(LIKELY(fc->co)){
		fc->p &= CO_MASK;
		// hack to reset the coro object
		aco_t *co = fc->co;
		co->fp = fp;
		co->arg = arg;
		co->reg[ACO_REG_IDX_RETADDR] = fp;
		co->reg[ACO_REG_IDX_SP] = co->share_stack->align_retptr;
		co->is_end = 0;
	}else{
		fc->co = aco_create(fhk_co_s.main, fhk_co_s.sstk, 0, fp, arg);
	}

	return fc;
}

#define fhk_co_destroy(fc) (fc)->p |= CO_FREE
#define fhk_co_arg()       aco_get_arg()

// TODO: in the new implementation, store fc->r in rax when switching coroutines
// no need to go through fhk_co struct

static inline fhk_status fhk_co_resume(fhk_co *fc){
	aco_resume(fc->co);
	return fc->status;
}

static inline void fhk_co_yield(fhk_co *fc, fhk_status status){
	fc->status = status;
	aco_yield();
}
