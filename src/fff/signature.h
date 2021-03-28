#include <stdint.h>

#include "../fhk/def.h"

typedef union {
	char token[4];
	uint32_t u32;
} fff_sigtoken;

typedef struct {
	uint8_t np, nr;
	uint8_t types[2*G_MAXEDGE];
} fff_signature;

static_assert(G_MAXEDGE <= 0xff);

int fff_parse_signature(fff_signature *s, const char *sig, const fff_sigtoken *def);
