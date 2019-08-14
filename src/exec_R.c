#define R_NO_REMAP

#include "lex.h"
#include "exec.h"
#include "def.h"

#include <stdlib.h>
#include <string.h>
#include <assert.h>
#include <Rinterface.h>
#include <Rinternals.h>
#include <Rembedded.h>

#ifndef M2_R_HOME
// R requires R_HOME envvar to be set so use this as a default if the envvar is not set
#define M2_R_HOME "/usr/lib/R"
#endif

struct ex_R_func {
	// must be first
	ex_func ex;

	// TODO preallocate SEXP for all these, should be faster
	SEXP call;
	int narg;
	ptype *argt;
	int nret;
	ptype *rett;
};

/* global state goes here - R is full of global state anyway so it doesn't make
 * sense to tie this to ex_R_func or some other non-global object */
struct GS {
	// I'm using an R list to store the already sourced files because I'm lazy
	SEXP sourced;

	// pairlist of all calls, stored here to protect them from gc
	SEXP calls;
};

static struct GS *GS = NULL;

static int ex_R_exec(struct ex_R_func *X, pvalue *ret, pvalue *argv);
static void ex_R_destroy(struct ex_R_func *X);

static const struct ex_impl EX_R = {
	.exec = (ex_exec_f) ex_R_exec,
	.destroy = (ex_destroy_f) ex_R_destroy
};

static void init_R_embedded();
static int source(const char *fname);
static int sourcef(const char *fname);
static SEXP eval(SEXP call, int *err);
static SEXP make_call(struct ex_R_func *X, const char *func);
static void copy_args(struct ex_R_func *X, pvalue *argv);
static void copy_ret(struct ex_R_func *X, pvalue *ret, SEXP s);
static void add_call(SEXP call);
static void remove_call(SEXP call);

ex_func *ex_R_create(const char *fname, const char *func, int narg, ptype *argt, int nret,
		ptype *rett){

	init_R_embedded();
	source(fname);

	struct ex_R_func *X = malloc(sizeof *X);
	X->ex.impl = &EX_R;

	X->narg = narg;
	X->argt = malloc(narg * sizeof(ptype));
	memcpy(X->argt, argt, narg * sizeof(ptype));

	X->nret = nret;
	X->rett = malloc(nret * sizeof(ptype));
	memcpy(X->rett, rett, nret * sizeof(ptype));

	SEXP call = make_call(X, func);
	X->call = call;
	add_call(call);

	return (ex_func *) X;
}

static int ex_R_exec(struct ex_R_func *X, pvalue *ret, pvalue *argv){
	copy_args(X, argv);
	int err;
	SEXP r = eval(X->call, &err);
	copy_ret(X, ret, r);
	return err;
}

static void ex_R_destroy(struct ex_R_func *X){
	remove_call(X->call);
	free(X->argt);
	free(X->rett);
	free(X);
}

static void init_R_embedded(){
	if(GS)
		return;

	GS = malloc(sizeof *GS);

	// XXX should probably check the return value, this can fail
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

	GS->sourced = Rf_list1(R_NilValue);
	PROTECT(GS->sourced);

	GS->calls = Rf_list1(R_NilValue);
	PROTECT(GS->calls);
}

static int source(const char *fname){
	for(SEXP s=CDR(GS->sourced); s != R_NilValue; s=CDR(s)){
		if(!strcmp(CHAR(CAR(s)), fname))
			return 0;
	}

	dv("R: sourcing %s\n", fname);
	int ret = sourcef(fname);
	if(ret){
		dv("R: error in source: %d\n", ret);
		return ret;
	}else{
		Rf_listAppend(GS->sourced, Rf_list1(Rf_mkChar(fname)));
		return 0;
	}
}

static int sourcef(const char *fname){
	SEXP call = Rf_lang2(Rf_install("source"), Rf_mkString(fname));

	PROTECT(call);
	int err;
	eval(call, &err);
	UNPROTECT(1);

	return err;
}

static SEXP eval(SEXP call, int *err){
	// XXX: R_tryEval catches errors but is slower since it sets some error handlers etc.
	// Rf_eval is the faster alternative but on error it longjumps to some weird place
	// XXX: Not sure what the env parameter does and what happens if you pass something
	// else than R_GlobalEnv

#ifdef DEBUG
	return R_tryEval(call, R_GlobalEnv, err);
#else
	return R_tryEvalSilent(call, R_GlobalEnv, err);
#endif

	// XXX: you can get the error string using R_curErrorBuf()
}

static SEXP make_call(struct ex_R_func *X, const char *func){
	SEXP fsym = Rf_install(func);
	SEXP ret = Rf_lang1(fsym);

	// allocations could cause R to free this while we are building it
	// so protecc it just in case
	PROTECT(ret);

	// all args are passed as real because R integers would be 32 bit anyway
	// so no point in using them
	for(int i=0;i<X->narg;i++)
		Rf_listAppend(ret, Rf_lang1(Rf_allocVector(REALSXP, 1)));

	UNPROTECT(1);

	return ret;
}

static void copy_args(struct ex_R_func *X, pvalue *argv){
	// first is the function name, then a linked list of 1-length vectors
	// representing the args
	ptype *argt = X->argt;

	for(SEXP s=CDR(X->call); s != R_NilValue; s=CDR(s), argt++, argv++){
		SEXP v = CAR(s);

		switch(*argt){
			case PT_REAL: *REAL(v) = argv->r; break;
			case PT_BIT:  *REAL(v) = unpackenum(argv->b); break;
			default:      UNREACHABLE();
		}
	}
}

static void copy_ret(struct ex_R_func *X, pvalue *ret, SEXP s){
	assert(TYPEOF(s) == REALSXP && LENGTH(s) == X->nret);

	double *r = REAL(s);
	for(int i=0;i<X->nret;i++,r++,ret++){
		switch(X->rett[i]){
			case PT_REAL: ret->r = *r; break;
			case PT_BIT:  ret->b = packenum((uint64_t) *r); break;
			default:      UNREACHABLE();
		}
	}
}

static void add_call(SEXP call){
	Rf_listAppend(GS->calls, Rf_list1(call));
}

static void remove_call(SEXP call){
	SEXP prev = GS->calls;
	SEXP next = CDR(prev);

	while(next != R_NilValue){
		if(CAR(next) == call){
			SETCDR(prev, CDR(next));
			return;
		}

		prev = next;
		next = CDR(next);
	}

	assert(0);
}
