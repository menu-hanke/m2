#include "fhk.h"

#if FHK_CO_x86_64_sysv
#include "co_x86_64_sysv.h"
#elif FHK_CO_LIBCO
#include "co_libco.h"
#endif

void fhkJ_yield(fhk_co *C, fhk_status s);
