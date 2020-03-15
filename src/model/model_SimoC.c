#include "model_SimoC.h"
#include "../def.h"

#include <stdlib.h>
#include <string.h>
#include <dlfcn.h>
#include <ffi.h>

#define SIMO_STATUS_OK 1

struct model_SimoC {
	struct model model;
	ffi_type **ffiatypes;
	ffi_cif cif;
	void *fp;
};

static int mod_SimoC_call(struct model_SimoC *m, pvalue *ret, pvalue *argv);
static void mod_SimoC_destroy(struct model_SimoC *m);

static const struct model_func MOD_SIMOC = {
	.call      = (model_call_f) mod_SimoC_call,
	.calibrate = NULL,
	.destroy   = (model_destroy_f) mod_SimoC_destroy
};

static int init_simo_cif(struct model_SimoC *m);
static void *load_simo_lib(const char *filename);

model *mod_SimoC_create(struct mod_SimoC_def *def){
	assert(!(def->flags & MODEL_CALIBRATED));

	void *handle = load_simo_lib(def->libname);
	if(!handle)
		return NULL;

	void *fp = dlsym(handle, def->func);
	if(!fp){
		mlib_errf("dlsym failed: %s", dlerror());
		return NULL;
	}

	struct model_SimoC *m = malloc(sizeof *m);
	m->fp = fp;

	mlib_initmodel(&m->model,
			&MOD_SIMOC,
			def->n_arg, def->atypes,
			def->n_ret, def->rtypes,
			0, def->flags
	);

	if(init_simo_cif(m)){
		mlib_destroymodel(&m->model);
		free(m);
		return NULL;
	}

	return (model *) m;
}

static int mod_SimoC_call(struct model_SimoC *m, pvalue *ret, pvalue *argv){
	unsigned nparg = m->model.n_arg;
	void *ffiarg[nparg+6];
	char err[200]; // simo uses 200 bytes for all error buffers so we do too
	err[0] = 0;
	ffi_sarg status; // return value
	int nres = 0; // simo sets this
	int *nres_ptr = &nres;

	int errorCheckMode = 0;
	double allowedRiskLevel = 0;
	double rectFactor = 1;

	mlib_exportd(&m->model, argv);

	for(size_t i=0;i<nparg;i++)
		ffiarg[i] = &argv[i];

	ffiarg[nparg]   = &nres_ptr;
	ffiarg[nparg+1] = &ret;
	ffiarg[nparg+2] = &err;
	ffiarg[nparg+3] = &errorCheckMode;
	ffiarg[nparg+4] = &allowedRiskLevel;
	ffiarg[nparg+5] = &rectFactor;

	ffi_call(&m->cif, m->fp, &status, ffiarg);

	if(status != SIMO_STATUS_OK){
		mlib_errf("simo error: %s", err);
		return MODEL_CALL_RUNTIME_ERROR;
	}

	if(nres != 1){
		mlib_errf("simo model returned %d results, expected 1", nres);
		return MODEL_CALL_INVALID_RETURN;
	}

	mlib_importd(&m->model, argv);

	return MODEL_CALL_OK;
}

static void mod_SimoC_destroy(struct model_SimoC *m){
	mlib_destroymodel(&m->model);
	free(m->ffiatypes);
	free(m);
}

static int init_simo_cif(struct model_SimoC *m){
	/* simo "calling convention":
	 *     - first put all the model args (there are m->model.n_arg of these, these are all double)
	 *     - next put int *nres, number of results
	 *     - next put void *res, result pointer (usually this is double, must be alloced
	 *       by caller)
	 *     - next put char *errors, error buffer (must be allocated by caller)
	 *     - next put: int errorCheckMode, double allowedRiskLevel, double rectFactor
	 *       (these are unused)
	 */

	unsigned nparg = m->model.n_arg;
	unsigned narg = nparg + 6;
	m->ffiatypes = malloc(narg * sizeof(*m->ffiatypes));

	// model args
	for(unsigned i=0;i<nparg;i++)
		m->ffiatypes[i] = &ffi_type_double;

	m->ffiatypes[nparg]   = &ffi_type_pointer; // int *res
	m->ffiatypes[nparg+1] = &ffi_type_pointer; // void *res
	m->ffiatypes[nparg+2] = &ffi_type_pointer; // char *errors
	m->ffiatypes[nparg+3] = &ffi_type_sint;    // int errorCheckMode
	m->ffiatypes[nparg+4] = &ffi_type_double;  // double allowedRiskLevel
	m->ffiatypes[nparg+5] = &ffi_type_double;  // double rectFactor

	ffi_status s = ffi_prep_cif(&m->cif, FFI_DEFAULT_ABI, narg, &ffi_type_sint, m->ffiatypes);
	if(s != FFI_OK){
		mlib_errf("ffi_prep_cif failed: %d", s);
		return 1;
	}

	return 0;
}

static void *load_simo_lib(const char *filename){
	void *handle = mlib_get_file_data(filename);

	if(!handle){
		dv("opening simo library: %s\n", filename);
		void *handle = dlopen(filename, RTLD_LAZY | RTLD_LOCAL);
		if(!handle){
			mlib_errf("dlopen failed: %s", dlerror());
			return NULL;
		}

		mlib_set_file_data(filename, handle);
	}

	return handle;
}
