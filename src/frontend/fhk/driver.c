#include "../../fhk/fhk.h"
#include "../../model/conv.h"
#include "../../mem.h"
#include "../../def.h"
#include "driver.h"

#include <assert.h>
#include <stdlib.h>
#include <stdalign.h>

// XXX (mieti vielä)
// tämä voi olla joka suora callback tai C api kutsu.
// jos on paljon side traceja (10+?), niin C api on tehokkaampi, eikä hidastu side tracejen
// määrän kasvatessa. tämän voi valita vaikka heuristiikalla.

// TODO: fhk joku -DFHK_USE_CALLBACKS tjsp, udata tulkitaan callbackina, jolloin kutsuketju
// menee seuraavasti:
//     fhk   ---callback-->   driver funktio   ---lua C api--->   lua
// tämä on todennäköisesti tehokkaampi kun sidetracet (lj 2.1 stitchaa sen kutsun muutenkin)

#define UD_ISLUA(ud)      ((ud) & 1)
#define UD_CPTR(ud)       ((void *)((ud) & 0xffffffffffff))
#define UD_CARGOFFSET(ud) ((ud) >> 48)

enum {
	VAR_CB   = 0,
	VAR_LUA  = 1,
	VAR_REFK = 2,
	VAR_REFX = 3
};

struct fhkD_cres *fhkD_continue(fhk_solver *S, void *udata, arena *arena){
#define R(...) ({                                             \
	struct fhkD_cres *_r = arena_malloc(arena, sizeof(*_r));  \
	*_r = (struct fhkD_cres){__VA_ARGS__};                    \
	_r;                                                       \
})
	for(;;){
		fhk_status status = fhk_continue(S);

		switch(FHK_CODE(status)){

			case FHK_OK:
				return NULL;

			case FHKS_SHAPE:
				// should never happen because caller sets shape table
				assert(!"caller didn't set shape table");
				return R(.status=FHKS_SHAPE, .handle=-1);

			case FHK_ERROR:
				// TODO
				return R(.status=FHK_ERROR, .handle=-1);

			case FHKS_MAPPING:
			case FHKS_MAPPING_INVERSE:
				{
					struct fhks_mapping *sm = (struct fhks_mapping *) FHK_ABC(status);
					uint64_t x = FHK_X(status);
					if(UNLIKELY(UD_ISLUA(x)))
						return R(
								.status = FHK_CODE(status),
								.handle = x >> (16*FHK_CODE(status)),
								.instance = sm->instance,
								.map_ss = sm->ss
						);

					struct fhkD_cmap *cm = UD_CPTR(x);
					fhkD_cmap_f fp = cm->fp[FHK_CODE(status) & 1];
					*sm->ss = fp(cm, udata + UD_CARGOFFSET(x), sm->instance);
					continue;
				}

			case FHKS_COMPUTE_GIVEN:
				{
					uint64_t x = FHK_X(status);
					int xi = FHK_A(status);
					int inst = FHK_B(status);

					switch(x & 0x3){
						case VAR_CB:
							{
								struct fhkD_cvar *cv = UD_CPTR(x);
								cv->fp(S, cv, udata + UD_CARGOFFSET(x), xi, inst);
								continue;
							}

						case VAR_LUA:
							return R(
									.status = FHKS_COMPUTE_GIVEN,
									.handle = x >> 16,
									.instance = inst,
									.xi = xi
							);

						case VAR_REFK:
							{
								void *p = (void *) (x >> 16);
								uint64_t offset = (x & 0xffff) >> 2;
								if(offset != (0xffff >> 2))
									p = *((void **) p) + offset;
								fhkS_give_all(S, xi, p);
								continue;
							}

						case VAR_REFX:
							{
								void *p = udata + ((x & 0xffff) >> 2);
								x >>= 16;
								for(; x; x>>=16)
									p = *((void **) p) + (x & 0x7fff);
								fhkS_give_all(S, xi, p);
								continue;
							}
					}

					// "warning: this statement may fall through"
					//     - gcc, 2020
					__builtin_unreachable();
				}

			case FHKS_COMPUTE_MODEL:
				{
					uint64_t x = FHK_X(status);
					struct fhks_cmodel *mcall = (struct fhks_cmodel *) FHK_ABC(status);
					struct fhkD_cmodel *cm = UD_CPTR(x);
					arena_ptr *p;

					// need to convert?
					if(UNLIKELY(cm->gsig)){
						p = arena_save(arena);

						for(size_t i=0;i<mcall->np;i++){
							if(cm->gsig[i] != cm->msig[i]){
								mcall_edge *e = mcall->edges+i;
								void *mv = arena_alloc(arena,
										e->n * MT_SIZEOF(cm->msig[i]),
										MT_SIZEOF(cm->msig[i])
								);

								int res = mt_cconv(mv, cm->msig[i], e->p, cm->gsig[i], e->n);

								// this shouldn't happen because all conversions produced by the
								// autoconverter are valid.
								if(UNLIKELY(res))
									return R(
											.status = FHKD_ERROR,
											.ewhat = FHKD_CONVERSION_FAILED
									);

								e->p = mv;
							}
						}

						// if we need to convert return values, reserve them now too
						for(size_t i=mcall->np;i<mcall->np+mcall->nr;i++){
							if(cm->gsig[i] != cm->msig[i]){
								mcall_edge *e = mcall->edges+i;
								// alloc extra space in the start to store the original pointer
								void **buf = arena_alloc(arena,
										sizeof(void *) + e->n*MT_SIZEOF(cm->msig[i]),
										alignof(void *)
								);
								buf[0] = e->p;
								e->p = buf+1;
							}
						}
					}

					int res = cm->fp(cm->model, mcall);

					if(UNLIKELY(res))
						return R(
								.status = FHKD_ERROR,
								.ewhat = FHKD_MODEL_FAILED
						);

					// if we stored return values in a temp buffer, read them back now
					if(UNLIKELY(cm->gsig)){
						for(size_t i=mcall->np;i<mcall->np+mcall->nr;i++){
							if(cm->gsig[i] != cm->msig[i]){
								mcall_edge *e = mcall->edges+i;
								void *buf = *(((void **) e->p)-1);
								int res = mt_cconv(buf, cm->msig[i], e->p, cm->gsig[i], e->n);

								// shouldn't happen
								if(UNLIKELY(res))
									return R(
											.status = FHKD_ERROR,
											.ewhat = FHKD_CONVERSION_FAILED
									);

								e->p = buf;
							}
						}

						arena_restore(arena, p);
					}

					continue;
				}
		}

		assert(!"invalid return");
		__builtin_unreachable();
	}

#undef R
}
