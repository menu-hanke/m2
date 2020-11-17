#include "../../fhk/fhk.h"
#include "../../model/conv.h"
#include "../../mem.h"
#include "../../def.h"
#include "driver.h"

#include <assert.h>
#include <stdlib.h>

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

#define D_DEF(S, D, s, a, U) fhk_solver *S, fhkD_driver *D, fhkD_status *s, arena *a, void *U

static int32_t d_mapcall(D_DEF(S, D, status, A, U), fhk_mapcall *mp, bool mp_inverse);
static int32_t d_gval(D_DEF(S, D, status, A, U), fhk_idx xi, fhk_inst x_inst);
static int32_t d_modcall(D_DEF(S, D, status, A, U), fhk_modcall *mc);
static int32_t d_mcall(D_DEF(S, D, status, A, U), fhkD_model *dm, fhk_modcall *mc);
static int32_t d_vrefa(D_DEF(S, D, status, A, U), fhk_idx xi, void *ref);

int32_t fhkD_continue(D_DEF(S, D, status, A, U)){
	fhk_status fs = fhk_continue(S);
	fhk_sarg a = FHK_ARG(fs);

	switch(FHK_CODE(fs)){

		case FHK_OK:
			return FHKD_OK;

		case FHKS_SHAPE:
			// TODO: currently this expects that the shape table is given
			assert(!"TODO");
			return FHKDE_FHK;

		case FHKS_MAPCALL:
		case FHKS_MAPCALLI:
			return d_mapcall(S, D, status, A, U, a.s_mapcall, IS_INVERSE(fs));

		case FHKS_GVAL:
			return d_gval(S, D, status, A, U, a.s_gval.idx, a.s_gval.instance);

		case FHKS_MODCALL:
			return d_modcall(S, D, status, A, U, a.s_modcall);

		case FHK_ERROR:
			status->e_status = fs;
			return FHKDE_FHK;
	}

	UNREACHABLE();
}

static int32_t d_mapcall(D_DEF(S, D, status, A, U), fhk_mapcall *mp, bool mp_inverse){
	fhkD_map *dm = &D->d_maps[mp->idx];

	switch(dm->tag){
		case FHKDP_FP:
			assert(!"TODO");
			break;

		case FHKDP_LUA:
			status->p_handle = dm->l_handle[mp_inverse];
			status->p_inst = mp->instance;
			status->p_ss = mp->ss;
			return FHKDL_MAP;

		default:
			UNREACHABLE();
	}

	return fhkD_continue(S, D, status, A, U);
}

static int32_t d_gval(D_DEF(S, D, status, A, U), fhk_idx xi, fhk_inst x_inst){
	fhkD_given *gv = &D->d_vars[xi];

	switch(gv->tag){
		case FHKDV_FP:
			gv->fp(S, gv->fp_arg, xi, x_inst);
			break;

		case FHKDV_LUA:
			status->v_handle = gv->l_handle;
			status->v_inst = x_inst;
			return FHKDL_VAR;

		case FHKDV_REFK:
			return d_vrefa(S, D, status, A, U, xi, D->d_vars[xi].rk_ref);

		case FHKDV_REFU:
			return d_vrefa(S, D, status, A, U, xi, U + D->d_vars[xi].ru_udata);

		default:
			UNREACHABLE();
	}

	return fhkD_continue(S, D, status, A, U);
}

static int32_t d_modcall(D_DEF(S, D, status, A, U), fhk_modcall *mc){
	fhkD_model *dm = &D->d_models[mc->idx];

	switch(dm->tag){
		case FHKDM_FP:
			assert(!"TODO");
			break;

		case FHKDM_MCALL:
			return d_mcall(S, D, status, A, U, dm, mc);

		case FHKDM_LUA:
			assert(!"TODO");
			break;

		default:
			UNREACHABLE();
	}

	return fhkD_continue(S, D, status, A, U);
}

static int32_t d_mcall(D_DEF(S, D, status, A, U), fhkD_model *dm, fhk_modcall *mc){
	// convert sig?
	if(UNLIKELY(dm->m_nconv > 0)){
		arena a = *A;

		// convert parameters
		for(size_t i=0;i<dm->m_npconv;i++){
			fhkD_conv *c = &dm->m_conv[i];
			fhk_mcedge *e = &mc->edges[c->ei];
			void *p = arena_alloc(&a, e->n * MT_SIZEOF(c->to), MT_SIZEOF(c->to));
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
			void **buf = arena_malloc(&a, sizeof(void *) + e->n*MT_SIZEOF(c->from));
			*buf = e->p;
			e->p = buf+1;
		}
	}

	int r = dm->m_fp(dm->m_model, (mcall_s *) mc);
	
	if(UNLIKELY(r)){
		status->e_mstatus = r;
		return FHKDE_MOD;
	}

	// need to convert returns?
	if(UNLIKELY(dm->m_npconv > dm->m_nconv)){
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

	return fhkD_continue(S, D, status, A, U);
}

static int32_t d_vrefa(D_DEF(S, D, status, A, U), fhk_idx xi, void *ref){
	fhkD_given *gv = &D->d_vars[xi];

	for(uint16_t i=0;i<4;i++){
		if(i >= gv->r_num)
			break;

		ref = *((void **)ref) + gv->r_off[i];
	}

	fhkS_give_all(S, xi, ref);
	return fhkD_continue(S, D, status, A, U);
}
