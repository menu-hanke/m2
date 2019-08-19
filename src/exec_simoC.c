#include "exec.h"
#include "exec_aux.h"
#include "lex.h"
#include "def.h"

#include <stdlib.h>
#include <string.h>
#include <dlfcn.h>
#include <ffi.h>

#define SIMO_STATUS_OK 1

struct ex_simoC_func {
	ex_func ex;
	struct exa_prototype proto;
	ffi_type **atypes;
	ffi_cif cif;
	void *fp;
};

struct simoC_lib {
	void *handle;
};

static int ex_simoC_exec(struct ex_simoC_func *X, pvalue *ret, pvalue *argv);
static void ex_simoC_destroy(struct ex_simoC_func *X);

static const struct ex_impl EX_SIMOC = {
	.exec = (ex_exec_f) ex_simoC_exec,
	.destroy = (ex_destroy_f) ex_simoC_destroy
};

static void init_simo_cif(struct ex_simoC_func *X);
static struct simoC_lib *load_simo_lib(const char *filename);

ex_func *ex_simoC_create(const char *libname, const char *func, int narg, ptype *argt, int nret,
		ptype *rett){

	struct ex_simoC_func *X = malloc(sizeof *X);
	X->ex.impl = &EX_SIMOC;

	exa_init_prototype(&X->proto, narg, argt, nret, rett);

	void *handle = load_simo_lib(libname)->handle;
	X->fp = dlsym(handle, func);
	if(!X->fp)
		DIEF(1, "dlsym failed: %s\n", dlerror());

	init_simo_cif(X);

	return (ex_func *) X;
}

static int ex_simoC_exec(struct ex_simoC_func *X, pvalue *ret, pvalue *argv){
	unsigned nparg = X->proto.narg;
	void *ffiarg[nparg+6];
	char err[200]; // simo uses 200 bytes for all error buffers so we do too
	ffi_sarg status; // return value
	int nres = 123456; // simo sets this
	int *nres_ptr = &nres;

	int errorCheckMode = 0;
	double allowedRiskLevel = 0;
	double rectFactor = 1;

	for(size_t i=0;i<nparg;i++)
		ffiarg[i] = &argv[i];

	ffiarg[nparg]   = &nres_ptr;
	ffiarg[nparg+1] = &ret;
	ffiarg[nparg+2] = &err;
	ffiarg[nparg+3] = &errorCheckMode;
	ffiarg[nparg+4] = &allowedRiskLevel;
	ffiarg[nparg+5] = &rectFactor;

	ffi_call(&X->cif, X->fp, &status, ffiarg);
	assert(nres == 1);

	if(status != SIMO_STATUS_OK){
		dv("simo error: %s\n", err);
		assert(0);
	}

	return !(status == SIMO_STATUS_OK);
}

static void ex_simoC_destroy(struct ex_simoC_func *X){
	exa_destroy_prototype(&X->proto);
	free(X->atypes);
	free(X);
}

static void init_simo_cif(struct ex_simoC_func *X){
	/* simo "calling convention":
	 *     - first put all the model args (there are X->proto.narg of these, these are all double)
	 *     - next put int *nres, number of results
	 *     - next put void *res, result pointer (usually this is double, must be alloced
	 *       by caller)
	 *     - next put char *errors, error buffer (must be allocated by caller)
	 *     - next put: int errorCheckMode, double allowedRiskLevel, double rectFactor
	 *       (these are unused)
	 */

	unsigned nparg = X->proto.narg;
	unsigned narg = nparg + 6;
	X->atypes = malloc(narg * sizeof(*X->atypes));

	// model args
	for(unsigned i=0;i<nparg;i++)
		X->atypes[i] = &ffi_type_double;

	X->atypes[nparg]   = &ffi_type_pointer; // int *res
	X->atypes[nparg+1] = &ffi_type_pointer; // void *res
	X->atypes[nparg+2] = &ffi_type_pointer; // char *errors
	X->atypes[nparg+3] = &ffi_type_sint;    // int errorCheckMode
	X->atypes[nparg+4] = &ffi_type_double;  // double allowedRiskLevel
	X->atypes[nparg+5] = &ffi_type_double;  // double rectFactor

	ffi_status s = ffi_prep_cif(&X->cif, FFI_DEFAULT_ABI, narg, &ffi_type_sint, X->atypes);
	if(s != FFI_OK)
		DIEF(1, "ffi_prep_cif failed: %d\n", s);
}

static struct simoC_lib *load_simo_lib(const char *filename){
	struct simoC_lib *lib = exa_get_file_data(filename);

	if(!lib){
		dv("opening simo library: %s\n", filename);
		void *handle = dlopen(filename, RTLD_LAZY | RTLD_LOCAL);
		if(!handle)
			DIEF(1, "dlopen failed: %s\n", dlerror());

		lib = malloc(sizeof(*lib));
		lib->handle = handle;
		exa_set_file_data(filename, lib);
	}

	return lib;
}
