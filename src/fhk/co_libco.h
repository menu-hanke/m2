#include <libco.h>
#include <stdbool.h>

typedef struct {
	void (*fp)(fhk_solver *);
	fhk_status status;
	cothread_t caller;
	cothread_t co;
	bool destroy;
} fhk_co;

void fhk_co_init(fhk_co *co, void *fp);
void fhk_co_done(fhk_co *co);
