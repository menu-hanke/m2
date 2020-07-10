#pragma once

#include "model.h"

#include <stdint.h>
#include <stdbool.h>

typedef uint8_t mt_type;
typedef uint8_t mt_insn;

struct mt_sig {
	uint8_t np, nr;
	mt_type typ[];
};

#define MT_SIG_VA_SIZE(sig) (((sig)->np + (sig)->nr)*sizeof(mt_type))

// idea: if support for more complex types is needed (eg. blobs, xmm vectors,
// custom size/alignment, ...), use something like
// 
// struct {
//     size : 16;
//     typ  : 3; // uint, sint, mask, fp, bool, ptr
//     vec  : 2; // __attribute__((vector_size(...)))
//     set  : 1;
//     unused : 10;
// } // 32 bits
//
// and do the mask comparisons using strstr (or similar) against the signature instead
//
// note: this isn't needed if only vecs are needed, just add MT_V2F, MT_V2D, ..., below
// (though there's not enough space for avx512 vectors etc. in the enum)

enum {
	MT_UINT8,
	MT_UINT16,
	MT_UINT32,
	MT_UINT64,

	MT_SINT8,
	MT_SINT16,
	MT_SINT32,
	MT_SINT64,

	MT_MASK8,
	MT_MASK16,
	MT_MASK32,
	MT_MASK64,

	MT__INT = MT_MASK64, // end of integers

	MT_FLOAT,
	MT_DOUBLE,
	MT_BOOL,
	MT_POINTER,

	MT__END,
	MT_INVALID = MT__END,

	MT_SET = 0x20 // set flag
};

enum {
	MT_CONV_EBUF = -1,
	MT_CONV_ESIG = -2,
	MT_CONV_ETYP = -3
};

static_assert(MT__END < MT_SET);
static_assert((MT_SET|MT__END) < 64); // all combinations fit in a 64-bit mask

#define MT_s(t) (1ULL << (t))
#define MT_S(t) (1ULL << ((t) | MT_SET))
#define MT_sS(t) (MT_s(t) | MT_S(t))

// float              f
// double             d
// uintX_t            uX
// intX_t             iX
// maskX              mX
// bool               z
// pointer            p

void mt_sig_info(const char *sig, size_t *np, size_t *nr);
uint64_t mt_sig_mask(const char *sig);
bool mt_sig_check(const char *sig, uint64_t mask);
void mt_sig_parse(const char *sig, mt_type *typ);
void mt_sig_copy(struct mt_sig *dest, struct mt_sig *src);
size_t mt_sizeof(mt_type typ);
mt_type mt_autoconv(mt_type typ, uint64_t mask);
int mt_autoconv_sig1(struct mt_sig *sig, uint64_t mask);
int mt_autoconv_sigm(struct mt_sig *sig, uint64_t *mask);
int mt_sig_conv(struct mt_sig *from, struct mt_sig *to, mt_insn *insn, int ni);
mt_insn *mt_conv(mcall_s *mc, mt_insn *insn);
