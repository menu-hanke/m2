#include <libco.h>
#include <stdbool.h>
#include <stddef.h>

typedef struct {
	void (*fp)(fhk_solver *);
	fhk_status status;
	cothread_t caller;
	cothread_t co;
	bool destroy;
} fhk_co;

void fhk_co_init(fhk_co *C, size_t maxstack, void *fp);
void fhk_co_done(fhk_co *C);
