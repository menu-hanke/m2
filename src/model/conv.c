#include "../def.h"
#include "../mem.h"
#include "model.h"
#include "conv.h"

#include <stdint.h>
#include <stdbool.h>
#include <ctype.h>
#include <string.h>

#define MT_RETURN MT__END
#define SIG_DONE   (-1)
#define SIG_INVAL  (-2)

static int sig_tok(const char **sig);
static int conv_choose_range(mt_type from, mt_type to, uint64_t mask);
static bool emit_conv(mt_type from, mt_type to, mt_insn **insn);

void mt_sig_info(const char *sig, size_t *np, size_t *nr){
	*np = 0;
	*nr = 0;

	size_t *acc = np;

	for(; *sig; sig++){
		if(*sig == '>'){
			acc = nr;
			continue;
		}

		if(!isdigit(*sig))
			(*acc)++;
	}
}

uint64_t mt_sig_mask(const char *sig){
	uint64_t mask = 0;
	int typ;

	while((typ = sig_tok(&sig)) >= 0)
		mask |= 1ULL << typ;

	return mask;
}

bool mt_sig_check(const char *sig, uint64_t mask){
	int typ;

	while((typ = sig_tok(&sig)) >= 0){
		if((~mask) & (1ULL << typ))
			return false;
	}

	return typ == SIG_DONE;
}

// typ should be preallocated for np+nr slots (check mt_sig_info)
void mt_sig_parse(const char *sig, mt_type *typ){
	int t;
	
	while((t = sig_tok(&sig)) >= 0){
		if(UNLIKELY(t == MT_RETURN))
			continue;
		*typ++ = t;
	}
}

void mt_sig_copy(struct mt_sig *dest, struct mt_sig *src){
	memcpy(dest, src, sizeof(*src) + MT_SIG_VA_SIZE(src));
}

size_t mt_sizeof(mt_type typ){
	typ &= ~MT_SET;

	if(typ <= MT__INT)
		return 1ULL << (typ & 3);

	switch(typ){
		case MT_FLOAT: return sizeof(float);
		case MT_DOUBLE: return sizeof(double);
		case MT_BOOL: return 1;
		case MT_POINTER: return sizeof(void *);
	}

	return 0;
}

// parameter autoconversion rules:
//
//     type     conversion (in order of preference)
//     ----     -----------------------------------
//     float    double
//     uintX_t  uintY_t, intY_t (Y > X), double, float
//     intX_t   intY_t (Y > X), double, float
//     maskX    maskY_t (Y > X), uintZ_t, intZ_t, double, float
//     bool     uintY_t, intY_t, double, float
//
// set <-> singleton is not autoconverted
mt_type mt_autoconv(mt_type typ, uint64_t mask){
	if(LIKELY(mask & (1ULL << typ)))
		// nothing to convert
		return typ;

	mt_type set = typ & MT_SET;
	mask >>= set;
	typ &= ~MT_SET;

#define MAYBE(f, t) {                                   \
		int _typ = conv_choose_range(f, t, mask);       \
		if(_typ >= 0)                                   \
			return set|_typ;                            \
	}

	if(typ == MT_FLOAT){
		MAYBE(MT_DOUBLE, MT_DOUBLE);
		return MT_INVALID;
	}

	// u8, ..., u32
	if(typ <= MT_UINT32)
		MAYBE(typ+1, MT_UINT64);

	// u8, ..., u64, i8, ..., i64
	if(typ <= MT_SINT64){
		MAYBE(MT_SINT8 + (typ&3) + 1, MT_SINT64); // bigger intX_t?
		MAYBE(MT_FLOAT, MT_DOUBLE); // any fp?
		return MT_INVALID;
	}

	// mask8, ..., mask64
	if(typ <= MT_MASK64){
		MAYBE(MT_MASK8 + (typ&3) + 1, MT_MASK64); // bigger mask?
		MAYBE(MT_UINT8, MT_UINT64); // any uint?
		MAYBE(MT_SINT8, MT_SINT8); // any sint?
		MAYBE(MT_FLOAT, MT_DOUBLE); // any fp?
		return MT_INVALID;
	}

	if(typ == MT_BOOL){
		MAYBE(MT_UINT8, MT_SINT64); // any integer?
		MAYBE(MT_FLOAT, MT_DOUBLE); // any fp?
		return MT_INVALID;
	}

	return MT_INVALID;

#undef MAYBE
}

int mt_autoconv_sig1(struct mt_sig *sig, uint64_t mask){
	for(size_t i=0;i<sig->np+sig->nr;i++){
		sig->typ[i] = mt_autoconv(sig->typ[i], mask);
		if(UNLIKELY(sig->typ[i] == MT_INVALID))
			return -(i+1);
	}

	return 0;
}

int mt_autoconv_sigm(struct mt_sig *sig, uint64_t *mask){
	for(size_t i=0;i<sig->np+sig->nr;i++){
		sig->typ[i] = mt_autoconv(sig->typ[i], *mask++);
		if(UNLIKELY(sig->typ[i] == MT_INVALID))
			return -(i+1);
	}

	return 0;
}

int mt_sig_conv(struct mt_sig *from, struct mt_sig *to, mt_insn *insn, int ni){
	if(from->np != to->np || from->nr != to->nr)
		return MT_CONV_ESIG;

	// TODO
	
	(void)insn;
	(void)ni;

	for(size_t i=0;i<to->np+to->nr;i++){
		if(from->typ[i] != to->typ[i])
			return MT_CONV_ETYP - i;
	}

	return 0;
}

static int sig_tok(const char **sig){
	char c = *(*sig)++;

	// uppercase ?
	int flags = ~c & MT_SET;

	switch(c | MT_SET){
		case 'f': return flags | MT_FLOAT;
		case 'd': return flags | MT_DOUBLE;
		case 'z': return flags | MT_BOOL;
		case 'p': return flags | MT_POINTER;
		case 'u': flags |= MT_UINT8; break;
		case 'i': flags |= MT_SINT8; break;
		case 'm': flags |= MT_MASK8; break;
		case '>': return MT_RETURN;
		case MT_SET: return SIG_DONE; // 0
		default: return SIG_INVAL;
	}

	switch(*(*sig)++){
		case '8': break;
		case '1': if(UNLIKELY(*(*sig)++ != '6')) return SIG_INVAL; flags |= 1; break;
		case '3': if(UNLIKELY(*(*sig)++ != '2')) return SIG_INVAL; flags |= 2; break;
		case '6': if(UNLIKELY(*(*sig)++ != '4')) return SIG_INVAL; flags |= 3; break;
		default: return SIG_INVAL;
	}

	return flags;
}

static int conv_choose_range(mt_type from, mt_type to, uint64_t mask){
	// prefer big types
	for(mt_type t=to; t>=from; t--){
		if(mask & (1ULL << t))
			return t;
	}

	return -1;
}

// type conversion "compiler".
// these are roughly C type conversion semantics. note that this is different from the
// parameter autoconverter, which just picks autoconversion types.
//
// integer  ->  integer       widen/narrow
// integer  ->  fp            round
// integer  ->  mask          1 << value
// integer  ->  bool          value != 0
// fp       ->  integer       round
// fp       ->  fp            round
// fp       ->  mask          fp -> integer -> mask
// fp       ->  bool          value != 0.0
// mask     ->  integer       lsb
// mask     ->  fp            mask -> integer -> fp
// mask     ->  mask          widen/narrow
// bool     ->  integer       true->1, false->0
// bool     ->  fp            true->1.0, false->0.0
//
static bool emit_conv(mt_type from, mt_type to, mt_insn **insn){
	// TODO
	(void)insn;
	return from == to;
}
