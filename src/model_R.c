#define R_NO_REMAP

#include "model.h"
#include "model_aux.h"
#include "model_R.h"
#include "type.h"

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

struct model_R {
	struct model model;
	enum mod_R_calib_mode mode;
	SEXP call;
};

/* global state goes here - R is full of global state anyway so it doesn't make
 * sense to tie this to ex_R_func or some other non-global object */
struct GS {
	// pairlist of all calls, stored here to protect them from gc
	SEXP calls;
};

static struct GS *GS = NULL;

static int mod_R_call(struct model_R *m, pvalue *ret, pvalue *argv);
static void mod_R_calibrate(struct model_R *m);
static void mod_R_destroy(struct model_R *m);

static const struct model_func MOD_R = {
	.call      = (model_call_f) mod_R_call,
	.calibrate = (model_calibrate_f) mod_R_calibrate,
	.destroy   = (model_destroy_f) mod_R_destroy
};

static void init_R_embedded();
static int source(const char *fname);
static int sourcef(const char *fname);
static void rerror();
static SEXP eval(SEXP call, int *err);
static SEXP make_call(struct model_R *m, const char *func);
static void add_call(SEXP call);
static void remove_call(SEXP call);

model *mod_R_create(struct mod_R_def *def){
	init_R_embedded();
	if(source(def->fname))
		return NULL;

	struct model_R *m = malloc(sizeof *m);
	maux_initmodel(&m->model,
			&MOD_R,
			def->n_arg, def->atypes,
			def->n_ret, def->rtypes,
			def->n_coef, def->flags
	);

	m->mode = def->mode;

	SEXP call = make_call(m, def->func);
	m->call = call;
	add_call(call);

	return (model *) m;
}

static int mod_R_call(struct model_R *m, pvalue *ret, pvalue *argv){
	maux_exportd(&m->model, argv);

	SEXP s = CDR(m->call);
	for(unsigned i=0;i<m->model.n_arg;i++,argv++,s=CDR(s))
		*REAL(CAR(s)) = argv->f64;

	int err;

	SEXP r = eval(m->call, &err);

	if(err){
		rerror();
		return MODEL_CALL_RUNTIME_ERROR;
	}

	if(TYPEOF(r) != REALSXP || (unsigned)LENGTH(r) != m->model.n_ret){
		maux_errf("Invalid return (type: %d length: %d) expected (type: %d length: %d)",
				TYPEOF(r), LENGTH(r), REALSXP, m->model.n_arg);
		return MODEL_CALL_INVALID_RETURN;
	}

	memcpy(ret, REAL(r), m->model.n_ret * sizeof(*ret));
	maux_importd(&m->model, ret);

	return MODEL_CALL_OK;
}

static void mod_R_calibrate(struct model_R *m){
	SEXP s = CDR(m->call);

	// skip args, after this s points to coefficients
	for(unsigned i=0;i<m->model.n_arg;i++)
		s = CDR(s);

	if(m->mode == MOD_R_EXPAND){
		for(unsigned i=0;i<m->model.n_coef;i++,s=CDR(s)){
			*REAL(CAR(s)) = m->model.coefs[i];
			//dv("calibrate coeff[%d] = %f\n", i, *REAL(CAR(s)));
		}
	}else{
		memcpy(REAL(CAR(s)), m->model.coefs, m->model.n_coef * sizeof(*m->model.coefs));
	}
}

static void mod_R_destroy(struct model_R *m){
	maux_destroymodel(&m->model);
	remove_call(m->call);
	free(m);
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

	GS->calls = Rf_list1(R_NilValue);
	PROTECT(GS->calls);
}

static int source(const char *fname){
	if(maux_get_file_data(fname))
		return 0;

	dv("R: sourcing %s\n", fname);
	int ret = sourcef(fname);
	if(ret){
		rerror();
		return ret;
	}

	maux_set_file_data(fname, (void *)1);
	return 0;
}

static int sourcef(const char *fname){
	SEXP call = Rf_lang2(Rf_install("source"), Rf_mkString(fname));

	PROTECT(call);
	int err;
	eval(call, &err);
	UNPROTECT(1);

	return err;
}

static void rerror(){
	maux_errf("R error: %s", R_curErrorBuf());
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
}

static SEXP make_call(struct model_R *m, const char *func){
	SEXP fsym = Rf_install(func);
	SEXP ret = Rf_lang1(fsym);

	// allocations could cause R to free this while we are building it
	// so protecc it just in case
	PROTECT(ret);

	// all args are passed as real because R integers would be 32 bit anyway
	// so no point in using them
	for(unsigned i=0;i<m->model.n_arg;i++)
		Rf_listAppend(ret, Rf_lang1(Rf_allocVector(REALSXP, 1)));

	if(MODEL_ISCALIBRATED(&m->model)){
		if(m->mode == MOD_R_EXPAND){
			for(unsigned i=0;i<m->model.n_coef;i++)
				Rf_listAppend(ret, Rf_lang1(Rf_allocVector(REALSXP, 1)));
		}else{
			Rf_listAppend(ret, Rf_allocVector(REALSXP, m->model.n_coef));
		}
	}

	UNPROTECT(1);

	return ret;
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
