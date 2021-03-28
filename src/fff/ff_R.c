#include "fff.h"
#include "def.h"
#include "signature.h"
#include "err.h"

#include "../fhk/fhk.h"

#include <stdlib.h>
#include <stdint.h>
#include <stdbool.h>
#include <string.h>
#include <assert.h>
#include <Rinterface.h>
#include <Rinternals.h>
#include <Rembedded.h>

#ifndef FFF_R_HOME
// R requires R_HOME envvar to be set so use this as a default if the envvar is not set
#define FFF_R_HOME "/usr/lib/R"
#endif

// TODO: Rf_eval is faster
#if FFF_DEBUG
#define r_eval(s,e) R_tryEval(s, R_GlobalEnv, e)
#else
#define r_eval(s,e) R_tryEvalSilent(s, R_GlobalEnv, e)
#endif

#define SIG_BASE(s) ((s) >> 1)
#define SIG_VECTOR  0x1
#define SIG_REAL 0
#define SIG_INT  1
#define SIG_LGL  2

static const fff_sigtoken sigtok[] = {
	{ "f64" }, // REALSXP scalar
	{ "F64" }, // REALSXP vector
	{ "i32" }, // INTSXP  scalar
	{ "I32" }, // INTSXP  vector
	{ "z" },   // LGLSXP  scalar
	{ "Z" },   // LGLSXP  vector
	{ .u32=0 }
};

static const char LOADER[] = {
#include "loader.r.in"
};

// parameter/return value conversion:
//
// +----------+---------+--------+
// |   7..3   |    2    |  1..0  |
// +----------+---------+--------+
// | SEXPTYPE | cv.type | cv.arg |
// +----------+---------+--------+
//
// +--------------+--------------+
// |    cv.type   |   cv.arg     |
// +--------------+--------------+
// | raw (0)      |  log2(size)  |
// +--------------+--------------+
// | convert (1)  | 0: lgl->bool |
// |              | 1: bool->lgl |
// +--------------+--------------+
#define CV_SXP(typ)  ((typ) << 3)
#define CV_RAW(size) ((!!((size)&0xa)) | ((!!((size)&0xc))<<1))
#define CV_LGL2BOOL  0x4
#define CV_BOOL2LGL  0x5

#define CV_SEXPTYPE(cv) ((cv) >> 3)
#define CV_CONV(cv)     ((cv) & 0x7)
#define CV_ISCONV(cv)   ((cv) & 0x4)

enum {
	//                 return value is a ...
	RET_VEC_SCALAR, // * vector where each element is a scalar return
	RET_VEC_VEC,    // * single vector, single return
	RET_LIST_VEC    // * list of vector returns
};

struct ff_R {
	struct ff_R *prev;
	SEXP wrapper;
	SEXP deanchor;
	SEXP fail;

	uint8_t mode;
	uint8_t cv[];
};

static void r_init();
static void r_error(struct fff_state *F);
static SEXP r_wrapper(const char *file, const char *func, fff_signature *sig);
static void r_lgl2bool(uint8_t *dest, int *src, size_t n);
static void r_bool2lgl(int *dest, uint8_t *src, size_t n);
static void r_copyvec(void *dest, void *src, size_t n, uint8_t cv);
static void r_fail(struct ff_R *ff, const char *mes);

fff_handle fffR_create(struct fff_state *F, const char *file, const char *func,
		const char *signature){

	fff_signature sig;
	if(fff_parse_signature(&sig, signature, sigtok)){
		fff_errsig(F, signature);
		return 0;
	}

	r_init();
	SEXP wda = r_wrapper(file, func, &sig);

	if(wda == R_NilValue){
		r_error(F);
		F->ecode = FFF_ERR_CRASH;
		return 0;
	}

	struct ff_R *ff = malloc(sizeof(*ff) + (sig.np+sig.nr)*sizeof(*ff->cv));
	if(!ff){
		fff_errmem(F);
		return 0;
	}

	ff->prev = F->vm_R;
	F->vm_R = ff;

	ff->wrapper = VECTOR_ELT(wda, 0);
	ff->deanchor = VECTOR_ELT(wda, 1);
	ff->fail = VECTOR_ELT(wda, 2);

	for(uint32_t i=0;i<sig.np+sig.nr;i++){
		switch(SIG_BASE(sig.types[i])){
			case SIG_REAL: ff->cv[i] = CV_SXP(REALSXP) | CV_RAW(sizeof(double)); break;
			case SIG_INT:  ff->cv[i] = CV_SXP(INTSXP) | CV_RAW(sizeof(int)); break;
			case SIG_LGL:  ff->cv[i] = CV_SXP(LGLSXP) | (i < sig.np ? CV_BOOL2LGL : CV_LGL2BOOL); break;
			default: UNREACHABLE();
		}
	}

	if(sig.nr == 1){
		ff->mode = RET_VEC_VEC;
	}else{
		ff->mode = RET_VEC_SCALAR;

		for(uint32_t i=sig.np;i<sig.np+sig.nr;i++){
			if(sig.types[i] & SIG_VECTOR){
				ff->mode = RET_LIST_VEC;
				break;
			}
		}
	}

	return (fff_handle) ff;
}

int32_t fffR_call(struct fff_state *F, fff_handle func, fhk_modcall *mc){
	// unfortunately the lang vector used for the call needs to be recreated and copied every time:
	// https://stackoverflow.com/questions/59130859/is-it-possible-to-change-the-data-pointer-in-a-sexp
	
	struct ff_R *ff = (struct ff_R *) func;
	uint8_t *sig = ff->cv;
	fhk_mcedge *e = mc->edges;

	SEXP call = PROTECT(Rf_lang1(ff->wrapper));
	SEXP s = call;
	for(uint32_t i=0;i<mc->np;i++,sig++,e++){
		SEXP p = Rf_allocVector(CV_SEXPTYPE(*sig), e->n);
		r_copyvec(DATAPTR(p), e->p, e->n, *sig);
		p = Rf_lang1(p);
		SETCDR(s, p);
		s = p;
	}

	int rc;
	SEXP rv = r_eval(call, &rc);
	UNPROTECT(1);

	if(rc){
		r_error(F);
		return (F->ecode = FFF_ERR_CRASH);
	}

	switch(ff->mode){
		case RET_VEC_SCALAR:
			assert(Rf_length(rv) == mc->nr);
			assert(TYPEOF(rv) == CV_SEXPTYPE(*sig));
			{
				size_t rvsz = CV_SEXPTYPE(*sig) == REALSXP ? sizeof(double) : sizeof(int);
				void *p = DATAPTR(rv);

				for(uint32_t i=0;i<mc->nr;i++,e++,p+=rvsz){
					assert(e->n == 1);
					r_copyvec(e->p, p, 1, *sig);
				}
			}
			break;

		case RET_VEC_VEC:
			assert(mc->nr == 1);
			assert(TYPEOF(rv) == CV_SEXPTYPE(*sig));
			{
				size_t vlen = Rf_length(rv);
				if(vlen != e->n){
					r_fail(ff, "Wrong number of values");
					fff_errprintf(F, "%s (expected a vector of length %zu, got %zu)",
							R_curErrorBuf(), e->n, vlen);
					return (F->ecode = FFF_ERR_SIGNATURE);
				}

				r_copyvec(e->p, DATAPTR(rv), e->n, *sig);
			}
			break;

		case RET_LIST_VEC:
			assert(Rf_length(rv) == mc->nr);
			assert(TYPEOF(rv) == VECSXP);
			for(uint32_t i=0;i<mc->nr;i++,sig++,e++){
				SEXP v = VECTOR_ELT(rv, i);
				assert(TYPEOF(v) == CV_SEXPTYPE(*sig));

				size_t vlen = Rf_length(v);
				if(vlen != e->n){
					r_fail(ff, "Wrong number of values");
					fff_errprintf(F, "%s (return #%zu, expected %zu, got %zu)",
							R_curErrorBuf(), i, e->n, vlen);
					return (F->ecode = FFF_ERR_SIGNATURE);
				}

				r_copyvec(e->p, DATAPTR(v), e->n, *sig);
			}
			break;

		default:
			UNREACHABLE();
	}

	return FFF_OK;
}

void fffR_destroy(struct fff_state *F){
	struct ff_R *ff = F->vm_R;

	if(!ff)
		return;

	SEXP call = PROTECT(Rf_lang1(R_NilValue));

	while(ff){
		SETCAR(call, ff->deanchor);

		int rc;
		r_eval(call, &rc);

		// if it fails, it's a bug in the loader
		assert(!rc);

		struct ff_R *prev = ff->prev;
		free(ff);
		ff = prev;
	}
}

static void r_init(){
	static bool _init = false;
	if(_init)
		return;

	_init = true;

	// XXX should probably check the return value, this can fail
	if(!getenv("R_HOME"))
		setenv("R_HOME", FFF_R_HOME, 0);

	char *argv[] = {
		"R",
		"--silent",   // quiet
		"--slave",    // really quiet
		"--vanilla",  // don't save any temp files
		"--gui=none"  // man page doesn't say anything about this but it works anyway
	};

	dv("R: Rf_initEmbeddedR()\n");

	// don't hijack signal handlers
	R_SignalHandlers = 0;

	// Note: see https://github.com/s-u/rJava/blob/master/jri/src/Rinit.c
	// for other invasive R features to turn off
	// also possibly use Rf_initialize_R here instead?

	// no point in checking return value, this always returns 1
	Rf_initEmbeddedR(sizeof(argv)/sizeof(argv[0]), argv);
}

static void r_error(struct fff_state *F){
	fff_errprintf(F, "R error: %s", R_curErrorBuf());
}

static SEXP r_wrapper(const char *file, const char *func, fff_signature *sig){
	static SEXP r_wfunc = NULL;

	if(!r_wfunc){
		// this will crash the whole process if it fails but that's ok,
		// it shouldn't fail.
		r_wfunc = R_ParseEvalString(LOADER, R_GlobalEnv);
	}

	SEXP r_sig = PROTECT(Rf_allocVector(STRSXP, sig->nr));

	char r_rs[2] = {0, 0};
	for(uint32_t i=0;i<sig->nr;i++){
		switch(SIG_BASE(sig->types[sig->np+i])){
			case SIG_REAL: *r_rs = 'd'; break;
			case SIG_INT:  *r_rs = 'i'; break;
			case SIG_LGL:  *r_rs = 'z'; break;
			default: UNREACHABLE();
		}

		if(sig->types[sig->np+i] & SIG_VECTOR)
			*r_rs &= ~32; // uppercase vectors

		// this copies `r_rs`
		SET_STRING_ELT(r_sig, i, Rf_mkChar(r_rs));
	}

	SEXP r_file = PROTECT(Rf_mkString(file));
	SEXP r_func = PROTECT(Rf_mkString(func));

	SEXP call = PROTECT(Rf_lang4(r_wfunc, r_file, r_func, r_sig));

	int rc;
	SEXP wda = r_eval(call, &rc);
	UNPROTECT(4); // call, r_func, r_file, r_sig

	if(rc)
		return R_NilValue;

	assert(wda != R_NilValue);
	return wda;
}

static void r_lgl2bool(uint8_t *dest, int *src, size_t n){
	for(size_t i=0;i<n;i++,dest++,src++)
		*dest = !!*src;
}

static void r_bool2lgl(int *dest, uint8_t *src, size_t n){
	for(size_t i=0;i<n;i++,dest++,src++)
		*dest = *src;
}

static void r_copyvec(void *dest, void *src, size_t n, uint8_t cv){
	if(CV_ISCONV(cv)){
		switch(CV_CONV(cv)){
			case CV_LGL2BOOL:
				r_lgl2bool(dest, src, n);
				break;
			case CV_BOOL2LGL:
				r_bool2lgl(dest, src, n);
				break;
			default:
				UNREACHABLE();
		}
	}else{
		memcpy(dest, src, n << CV_CONV(cv));
	}
}

static void r_fail(struct ff_R *ff, const char *mes){
	// this is kind of a hacky way to do it.
	// you will get the error in R_curErrorBuf().
	SEXP r_mes = PROTECT(Rf_mkString(mes));
	SEXP call = PROTECT(Rf_lang2(ff->fail, r_mes));
	int rc;
	r_eval(call, &rc);
	UNPROTECT(2);
	assert(rc);
}
