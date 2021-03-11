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

#define fhk_co_jmp(co, fp) do {              \
		(co)->rip = (void*)(fp);             \
	} while(0)

#define fhk_co_init(co, stack, sz, fp) do {  \
		fhk_co_jmp(co, fp);                  \
		(co)->rsp = (void*)(stack) + (sz);   \
	} while(0)

#define FHK_CO_BUILTIN 1
