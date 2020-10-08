#include "fhk.h"
void fhkJ_yield(fhk_solver *S, fhk_status s);

#if FHK_CO_x86_64_sysv
#include "co_x86_64_sysv.h"
#elif FHK_CO_LIBCO
#include "co_libco.h"
#endif
