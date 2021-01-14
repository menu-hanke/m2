#define R_NO_REMAP

#include "model.h"
#include "conv.h"
#include "model_R.h"
#include "../def.h"

#include <stdlib.h>
#include <stdbool.h>
#include <string.h>
#include <assert.h>
#include <Rinterface.h>
#include <Rinternals.h>
#include <Rembedded.h>

#ifndef M2_R_HOME
// R requires R_HOME envvar to be set so use this as a default if the envvar is not set
#define M2_R_HOME "/usr/lib/R"
#endif

// R integer type is `int` (which is usually int32_t but technically platform dependent)
#define MT_RINT (MT_SINT8 | MT_SIZEFLAG(sizeof(int)))

// TODO: Rf_eval is faster
#ifdef DEBUG
#define r_eval(s,e) R_tryEval(s, R_GlobalEnv, e)
#else
#define r_eval(s,e) R_tryEvalSilent(s, R_GlobalEnv, e)
#endif

#define CV(sexptyp, insn) (((sexptyp) << 3) | (insn))
#define CV_SEXPTYPE(cv)   ((cv) >> 3)
#define CV_IS_CONV(cv)    ((cv) & 0b100)
#define CV_PARAM(cv)      ((cv) & 0b011)

enum {
	//              0xx : memcpy (1<<xx)
	CV_MEMCPY   = 0b000,
	//              1xx : conversion
	CV_LGL_BOOL = 0b100,
	CV_BOOL_LGL = 0b101
};

enum {
	//                 return value is a ...
	RET_VEC_SCALAR, // * vector where each element is a scalar return
	RET_VEC_VEC,    // * single vector, single return
	RET_LIST_VEC    // * list of vector returns
};

struct mod_R {
	SEXP wrapper;
	SEXP deanchor;
	SEXP fail;

	uint8_t mode;
	uint8_t cv[];
};

static const char LOADER[] = {
#include "loader.r.in"
};

static void r_init();
static void r_error();
static SEXP r_wrapper(const char *file, const char *func, struct mt_sig *sig);
static void r_copyvec(void *dest, void *src, size_t n, uint8_t cv);
static void r_lgl2bool(uint8_t *dest, int *src, size_t n);
static void r_bool2lgl(int *dest, uint8_t *src, size_t n);
static void r_mfail(struct mod_R *m, const char *mes);

uint64_t mod_R_types(){
	return MT_sS(MT_DOUBLE)   // REALSXP
		| MT_sS(MT_RINT)      // INTSXP
		| MT_sS(MT_BOOL);     // LGLSXP
}

struct mod_R *mod_R_create(const char *file, const char *func, struct mt_sig *sig){
	r_init();

	SEXP wda = r_wrapper(file, func, sig);

	if(wda == R_NilValue)
		return NULL;

	struct mod_R *m = malloc(sizeof(*m) + (sig->np+sig->nr)*sizeof(*m->cv));
	m->wrapper = VECTOR_ELT(wda, 0);
	m->deanchor = VECTOR_ELT(wda, 1);
	m->fail = VECTOR_ELT(wda, 2);

	for(size_t i=0;i<sig->np+sig->nr;i++){
		switch(sig->typ[i] & ~MT_SET){
			case MT_DOUBLE: m->cv[i] = CV(REALSXP, CV_MEMCPY | MT_SIZEFLAG(sizeof(double))); break;
			case MT_RINT:   m->cv[i] = CV(INTSXP, CV_MEMCPY | MT_SIZEFLAG(sizeof(int))); break;
			case MT_BOOL:   m->cv[i] = CV(LGLSXP, i < sig->np ? CV_BOOL_LGL : CV_LGL_BOOL); break;
			default:
				model_errf("R: %s:%s: invalid parameter type #%zu: %u", file, func, i, sig->typ[i]);
				free(m);
				return NULL;
		}
	}

	if(sig->nr == 1){
		m->mode = RET_VEC_VEC;
	}else{
		m->mode = RET_VEC_SCALAR;

		for(size_t i=sig->np;i<sig->np+sig->nr;i++){
			if(sig->typ[i] & MT_SET){
				m->mode = RET_LIST_VEC;
				break;
			}
		}
	}

	return m;
}

bool mod_R_call(struct mod_R *m, mcall_s *mc){
	// unfortunately the lang vector used for the call needs to be recreated and copied every time:
	// https://stackoverflow.com/questions/59130859/is-it-possible-to-change-the-data-pointer-in-a-sexp
	
	uint8_t *sig = m->cv;
	mcall_edge *e = mc->edges;

	SEXP call = PROTECT(Rf_lang1(m->wrapper));
	SEXP s = call;
	for(size_t i=0;i<mc->np;i++,sig++,e++){
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
		r_error();
		return false;
	}

	switch(m->mode){
		case RET_VEC_SCALAR:
			assert(Rf_length(rv) == mc->nr);
			assert(TYPEOF(rv) == CV_SEXPTYPE(*sig));
			{
				size_t rvsz = CV_SEXPTYPE(*sig) == REALSXP ? sizeof(double) : sizeof(int);
				void *p = DATAPTR(rv);

				for(size_t i=0;i<mc->nr;i++,e++,p+=rvsz){
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
					r_mfail(m, "Wrong number of values");
					model_errf("%s (expected a vector of length %zu, got %zu)",
							R_curErrorBuf(), e->n, vlen);
					return false;
				}

				r_copyvec(e->p, DATAPTR(rv), e->n, *sig);
			}
			break;

		case RET_LIST_VEC:
			assert(Rf_length(rv) == mc->nr);
			assert(TYPEOF(rv) == VECSXP);
			for(size_t i=0;i<mc->nr;i++,sig++,e++){
				SEXP v = VECTOR_ELT(rv, i);
				assert(TYPEOF(v) == CV_SEXPTYPE(*sig));

				size_t vlen = Rf_length(v);
				if(vlen != e->n){
					r_mfail(m, "Wrong number of values");
					model_errf("%s (return #%zu, expected %zu, got %zu)",
							R_curErrorBuf(), i, e->n, vlen);
					return false;
				}

				r_copyvec(e->p, DATAPTR(v), e->n, *sig);
			}
			break;

		default:
			UNREACHABLE();
	}

	return true;
}

void mod_R_destroy(struct mod_R *m){
	SEXP call = PROTECT(Rf_lang1(m->deanchor));
	int rc;
	r_eval(call, &rc);

	// if it fails, it's a bug in the loader
	assert(!rc);

	free(m);
}

void mod_R_cleanup(){
	Rf_endEmbeddedR(0);
}

static void r_init(){
	static bool _init = false;
	if(_init)
		return;

	_init = true;

	// XXX should probably check the return value, this can fail
	if(!getenv("R_HOME"))
		setenv("R_HOME", M2_R_HOME, 0);

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

static void r_error(){
	model_errf("R error: %s", R_curErrorBuf());
}

static SEXP r_wrapper(const char *file, const char *func, struct mt_sig *sig){
	static SEXP r_wfunc = NULL;

	if(!r_wfunc){
		// this will crash the whole process if it fails but that's ok,
		// it shouldn't fail.
		r_wfunc = R_ParseEvalString(LOADER, R_GlobalEnv);
	}

	SEXP r_sig = PROTECT(Rf_allocVector(STRSXP, sig->nr));

	char r_rs[2] = {0, 0};
	for(size_t i=0;i<sig->nr;i++){
		switch(sig->typ[sig->np+i] & ~MT_SET){
			case MT_DOUBLE: *r_rs = 'd'; break;
			case MT_RINT:   *r_rs = 'i'; break;
			case MT_BOOL:   *r_rs = 'z'; break;
			default:
				UNPROTECT(1);
				model_errf("%s/%s: invalid signature [%zu] = %u",
						file, func, sig->np+i, sig->typ[sig->np+i]);
				return R_NilValue;
		}

		if(sig->typ[sig->np+i] & MT_SET)
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

	if(rc){
		r_error();
		return R_NilValue;
	}

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
	if(CV_IS_CONV(cv)){
		switch(CV_PARAM(cv)){
			case CV_PARAM(CV_LGL_BOOL):
				r_lgl2bool(dest, src, n);
				break;
			case CV_PARAM(CV_BOOL_LGL):
				r_bool2lgl(dest, src, n);
				break;
			default:
				UNREACHABLE();
		}
	}else{ // memcpy
		memcpy(dest, src, n << CV_PARAM(cv));
	}
}

static void r_mfail(struct mod_R *m, const char *mes){
	// this is kind of a hacky way to do it.
	// you will get the error in R_curErrorBuf().
	SEXP r_mes = PROTECT(Rf_mkString(mes));
	SEXP call = PROTECT(Rf_lang2(m->fail, r_mes));
	int rc;
	r_eval(call, &rc);
	UNPROTECT(2);
	assert(rc);
}
