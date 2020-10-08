#include "fhk.h"

static_assert(sizeof(fhk_status) == 16);

typedef struct fhk_co {
	void *rip;    // 0x00
	void *rsp;    // 0x08  
	void *r12;    // 0x10
	void *r13;    // 0x18
	void *r14;    // 0x20
	void *r15;    // 0x28
	void *rbx;    // 0x30
	void *rbp;    // 0x38
	void *co_rsp; // 0x40
} fhk_co;

#define fhk_co_init(co, stack, sz, fp) do {  \
		(co)->rip = (void*)(fp);             \
		(co)->rsp = (void*)(stack) + (sz);   \
	} while(0)

// align to 16 before call, ie. 16n+8 on entry
// https://wiki.osdev.org/System_V_ABI
#define FHK_CO_STACK_ALLOC (FHK_CO_STACK+8)
#define FHK_CO_STACK_ALIGN 16

#define FHK_CO_BUILTIN 1
