#pragma once

#include <stdlib.h>
#include <assert.h>

#define SVEC(...) struct { size_t n; __VA_ARGS__ *data; }
#define SVECE(v, i) (v).data[({ assert((i) < (v).n); (i); })]
#define SVECSZ(v) ((v).n * sizeof(*(v).data))

// TODO this should probably do something smart if realloc fails
#define SVEC_RESIZE(v, s) do {\
	(v).n = (s);\
	(v).data = (v).data ?\
		realloc((v).data, SVECSZ(v)) :\
		malloc(SVECSZ(v));\
} while(0)

#define SVEC_XALLOC(v, s, xmalloc, udata) do {\
	(v).n = (s);\
	(v).data = (xmalloc)((udata), SVECSZ(v));\
} while(0)
