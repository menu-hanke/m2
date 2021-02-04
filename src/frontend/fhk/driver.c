#include "../../fhk/fhk.h"
#include "../../model/conv.h"
#include "../../mem.h"
#include "../../def.h"
#include "driver.h"

#include <assert.h>
#include <stdalign.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

// this ensures that an fhk_modcall can be cast as mcall_s, ie. no conversions are required
// between fhk/mcall modcalls
static_assert(
		offsetof(fhk_modcall, np) == offsetof(mcall_s, np)
		&& offsetof(fhk_modcall, nr) == offsetof(mcall_s, nr)
		&& offsetof(fhk_modcall, edges) == offsetof(mcall_s, edges)
		&& offsetof(fhk_mcedge, p) == offsetof(mcall_edge, p)
		&& offsetof(fhk_mcedge, n) == offsetof(mcall_edge, n)
);

static_assert(FHKS_MAPCALLI == (FHKS_MAPCALL|1));
#define IS_INVERSE(p) ((p) & 1)

static int32_t d_mcall(struct fhkD_driver *D, struct fhkD_model *dm, fhk_modcall *mc);
static void d_vrefa(struct fhkD_driver *D, fhk_idx xi, void *ref);

struct fhkD_driver *fhkD_create_driver(struct fhkD_mapping *M, size_t n_umem, fhk_solver *S,
		arena *mem){

	struct fhkD_driver *D = arena_alloc(mem, sizeof(*D) + n_umem, alignof(*D));
	D->M = *M;
	D->S = S;
	D->mem = mem;
	D->trace = false;

	return D;
}

// this used to be split into multiple functions that tailcalled fhkD_continue,
// but unfortunately clang had too much braindamage and couldn't compile it into a loop,
// so here everything is manually inlined.
// go blame clang developers.
int32_t fhkD_continue(struct fhkD_driver *restrict D){
	static const void *s_status[] = {
		[FHK_OK]        = &&s_ok,
		[FHKS_SHAPE]    = &&s_shape,
		[FHKS_MAPCALL]  = &&s_mapcall,
		[FHKS_MAPCALLI] = &&s_mapcall,
		[FHKS_VREF]     = &&s_vref,
		[FHKS_MODCALL]  = &&s_modcall,
		[FHK_ERROR]     = &&s_error
	};

	for(;;){
		if(UNLIKELY(D->trace)){
			D->trace = false;
			return FHKDL_TRACE;
		}

		fhk_status fs = fhk_continue(D->S);
		D->tr_status = fs;
		fhk_sarg a = FHK_ARG(fs);
		goto *s_status[FHK_CODE(fs)];

s_ok:
		return FHKD_OK;

s_mapcall:
		{
			fhk_mapcall *mp = a.s_mapcall;
			fhkD_map *dm = &D->M.maps[mp->mref.idx];
			D->trace = dm->trace;

			switch(dm->tag){
				case FHKDP_FP:
					assert(!"TODO");
					break;

				case FHKDP_LUA:
					D->status.p_handle = dm->l_handle[IS_INVERSE(fs)];
					D->status.p_inst = mp->mref.inst;
					D->status.p_ss = mp->ss;
					return FHKDL_MAP;

				default:
					UNREACHABLE();
			}

			continue;
		}

s_vref:
		{
			fhk_eref vref = a.s_vref;
			fhkD_given *gv = &D->M.vars[vref.idx];
			D->trace = gv->trace;

			switch(gv->tag){
				case FHKDV_FP:
					gv->fp(D, gv->fp_arg, vref);
					break;

				case FHKDV_LUA:
					D->status.v_handle = gv->l_handle;
					D->status.v_inst = vref.inst;
					return FHKDL_VAR;

				case FHKDV_REFK:
					d_vrefa(D, vref.idx, gv->rk_ref);
					break;

				case FHKDV_REFU:
					d_vrefa(D, vref.idx, D->umem + gv->ru_udata);
					break;

				default:
					UNREACHABLE();
			}

			continue;
		}

s_modcall:
		{
			fhk_modcall *mc = a.s_modcall;
			fhkD_model *dm = &D->M.models[mc->mref.idx];
			D->trace = dm->trace;
			int r;

			switch(dm->tag){
				case FHKDM_FP:
					assert(!"TODO");
					break;

				case FHKDM_MCALL:
					if((r = d_mcall(D, dm, mc)))
						return r;
					break;

				case FHKDM_LUA:
					assert(!"TODO");
					break;

				default:
					UNREACHABLE();
			}

			continue;
		}

s_shape:
		// TODO: currently this expects that the shape table is given
		assert(!"TODO");
s_error:
		D->status.e_status = fs;
		return FHKDE_FHK;
	}
}

static int32_t d_mcall(struct fhkD_driver *D, struct fhkD_model *dm, fhk_modcall *mc){
	// convert sig?
	if(UNLIKELY(dm->m_nconv > 0)){
		arena mem = *D->mem;

		// convert parameters
		for(size_t i=0;i<dm->m_npconv;i++){
			fhkD_conv *c = &dm->m_conv[i];
			fhk_mcedge *e = &mc->edges[c->ei];
			void *p = arena_alloc(&mem, e->n * MT_SIZEOF(c->to), MT_SIZEOF(c->to));
			int r = mt_cconv(p, c->to, e->p, c->from, e->n);

			// this shouldn't happen because all conversions produced by the
			// autoconverter are valid.
			if(UNLIKELY(r))
				return FHKDE_CONV;

			e->p = p;
		}

		// reserve space for converted return values
		for(size_t i=dm->m_npconv;i<dm->m_nconv;i++){
			fhkD_conv *c = &dm->m_conv[i];
			fhk_mcedge *e = &mc->edges[c->ei];

			// we need to write back to the original pointer so store it just before
			// the allocation
			void **buf = arena_malloc(&mem, sizeof(void *) + e->n*MT_SIZEOF(c->from));
			*buf = e->p;
			e->p = buf+1;
		}
	}

	if(!dm->m_fp(dm->m_model, (mcall_s *) mc))
		return FHKDE_MOD;

	// need to convert returns?
	if(UNLIKELY(dm->m_npconv < dm->m_nconv)){
		for(size_t i=dm->m_npconv;i<dm->m_nconv;i++){
			fhkD_conv *c = &dm->m_conv[i];
			fhk_mcedge *e = &mc->edges[c->ei];
			void *buf = *(((void **) e->p) - 1);
			int r = mt_cconv(buf, c->to, e->p, c->from, e->n);

			// shouldn't happen
			if(UNLIKELY(r))
				return FHKDE_CONV;

			e->p = buf;
		}
	}

	return 0;
}

static void d_vrefa(struct fhkD_driver *D, fhk_idx xi, void *ref){
	fhkD_given *gv = &D->M.vars[xi];

	for(uint16_t i=0;i<4;i++){
		if(i >= gv->r_num)
			break;

		ref = *((void **)ref) + gv->r_off[i];
	}

	fhkS_give_all(D->S, xi, ref);
}
