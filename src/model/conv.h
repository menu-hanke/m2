#pragma once

#include "model.h"

#include <stdint.h>
#include <stdbool.h>

typedef uint8_t mt_type;

struct mt_sig {
	uint8_t np, nr;
	mt_type typ[];
};

#define MT_SIG_VA_SIZE(sig) (((sig)->np + (sig)->nr)*sizeof(mt_type))

#define MT_SIZEOF(t)   (1 << ((t) & 0b11))

enum { //          zfuss
	MT_SINT8   = 0b00000,
	MT_SINT16  = 0b00001,
	MT_SINT32  = 0b00010,
	MT_SINT64  = 0b00011,

	MT_UINT8   = 0b00100,
	MT_UINT16  = 0b00101,
	MT_UINT32  = 0b00110,
	MT_UINT64  = 0b00111,

	MT_FLOAT   = 0b01010,
	MT_DOUBLE  = 0b01011,

	MT_BOOL    = 0b10000,

	MT_POINTER = 0b11111,
	MT_SET    = 0b100000, // flag
	MT_INVALID = 0xff
};

#define MT_s(t) (1ULL << (t))
#define MT_S(t) (1ULL << ((t) | MT_SET))
#define MT_sS(t) (MT_s(t) | MT_S(t))

enum {
	MT_ECONV = -2, // invalid conversion
	MT_ELEN  = -1, // signature too long
	MT_EPARM = 1   // something wrong with parameter (error code is MT_EPARM+index)
};

// float              f
// double             d
// uintX_t            uX
// intX_t             iX
// bool               z
// pointer            p

int mt_sig_info(const char *sig, uint8_t *np, uint8_t *nr);
int mt_sig_parse(const char *sig, mt_type *typ);
void mt_sig_copy(struct mt_sig *dest, struct mt_sig *src);
mt_type mt_autoconv(mt_type typ, uint64_t mask);
int mt_cconv(void *dest, mt_type to, void *src, mt_type from, size_t n);
