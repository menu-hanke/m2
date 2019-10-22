#include "sim.h"
#include "vec.h"
#include "grid.h"
#include "vgrid.h"
#include "fhk.h"
#include "type.h"
#include "arena.h"
#include "gmap.h"
#include "gsolve.h"
#include "vmath.h"
#include "model/all.h"

/* evaluate to 1 if symbol is defined and 1 (i.e. -Dsymbol), otherwise 0
 * adapted from: https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/include/linux/kconfig.h?h=v5.4-rc1 */
#define comma_1 ,
#define second(a, b, ...) b
#define isdef__(x) second(x 1, 0)
#define isdef_(x) isdef__(comma_##x)
#define isdef(x) isdef_(x)

static const int HAVE_SOLVER_INTERRUPTS = isdef(M2_SOLVER_INTERRUPTS);
