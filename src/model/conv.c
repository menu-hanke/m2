#include "../def.h"
#include "../mem.h"
#include "model.h"
#include "conv.h"

#include <stdint.h>
#include <stdbool.h>
#include <ctype.h>
#include <string.h>

#define SIG_RETURN 65
#define SIG_DONE   (-1)
#define SIG_INVAL  (-2)

#define Z   0b10000
#define F   0b01000
#define U   0b00100
#define S8  0b00000
#define S16 0b00001
#define S32 0b00010
#define S64 0b00011
#define SS  0b00011

static int sig_tok(const char **sig);
static int conv_choose_range(mt_type from, mt_type to, uint64_t mask);

int mt_sig_info(const char *sig, uint8_t *np, uint8_t *nr){
	*np = 0;
	*nr = 0;

	uint8_t *acc = np;
	int pos = 0;

	for(; *sig; sig++){
		if(*sig == '>'){
			acc = nr;
			continue;
		}

		if(!isdigit(*sig)){
			pos++;
			if(!++*acc) // it overflowed
				return MT_ELEN;
		}
	}

	return 0;
}

// typ should be preallocated for np+nr slots (check mt_sig_info)
int mt_sig_parse(const char *sig, mt_type *typ){
	int t;
	int pos = 0;
	
	while((t = sig_tok(&sig)) >= 0){
		if(UNLIKELY(t == SIG_RETURN))
			continue;
		*typ++ = t;
		pos++;
	}

	return (t == SIG_DONE) ? 0 : (MT_EPARM+pos);
}

void mt_sig_copy(struct mt_sig *dest, struct mt_sig *src){
	memcpy(dest, src, sizeof(*src) + MT_SIG_VA_SIZE(src));
}

// parameter autoconversion rules (only non-lossy conversions):
//
//     type     conversion (in order of preference)
//     ----     -----------------------------------
//     float    double
//     uintX_t  uintY_t, intY_t (Y > X), double, float
//     intX_t   intY_t (Y > X), double, float
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
	if(typ >= MT_UINT8 && typ <= MT_UINT32)
		MAYBE(typ+1, MT_UINT64); // bigger uintX_t?

	// u8, ..., u64, i8, ..., i64
	if(typ <= MT_UINT64){
		MAYBE(MT_SINT8 + (typ&3) + 1, MT_SINT64); // bigger intX_t?
		MAYBE(MT_FLOAT, MT_DOUBLE); // any fp?
		return MT_INVALID;
	}

	if(typ == MT_BOOL){
		MAYBE(MT_SINT8, MT_UINT64); // any integer?
		MAYBE(MT_FLOAT, MT_DOUBLE); // any fp?
		return MT_INVALID;
	}

	return MT_INVALID;

#undef MAYBE
}

int mt_cconv(void *dest, mt_type to, void *src, mt_type from, size_t n){
	if(UNLIKELY(!n))
		return 0;

	if(UNLIKELY(from == to)){
		memcpy(dest, src, n*MT_SIZEOF(to));
		return 0;
	}

	// conversion between set and scalar?
	if(UNLIKELY((from^to) >= MT_SET))
		return MT_ECONV;

	// conversion involving pointers?
	// * first check quarantees both aren't pointers
	// * second check quarantees either both or neither are scalars
	if(UNLIKELY((from+0b100)^(to+0b100)) >= MT_SET)
		return MT_ECONV;

#define L(bits, lab) [bits] = &&lab - &&invalid
#define FF (F >> 1)         // from fp

	static const int16_t ld_offset[] = {
		// sint->
		L(  S8,  ldi8),
		L(  S16, ldi16),
		L(  S32, ldi32),
		L(  S64, ldi64),
		// uint->
		L(U+S8,  ldu8),
		L(U+S16, ldu16),
		L(U+S32, ldu32),
		L(U+S64, ldi64), // nothing to sign extend here
		// fp->
		L(F+S32, ldf32),
		L(F+S64, ldf64)
	};

	static const int16_t st_offset[] = {
		// int->int
		L(      S8,  stii8),
		L(      S16, stii16),
		L(      S32, stii32),
		L(      S64, stii64),
		// int->fp
		L(   F+S32,  stif32),
		L(   F+S64,  stif64),
		// int->bool
		L(   Z+S8,   stiz),
		// fp->int (no separate unsigned case, its ok due to representation)
		L(FF  +S8,   stfi8),
		L(FF  +S16,  stfi16),
		L(FF  +S32,  stfi32),
		L(FF  +S64,  stfi64),
		// fp->fp
		L(FF+F+S32,  stff32),
		L(FF+F+S64,  stff64),
		// fp->bool
		L(FF+Z+S8,   stfz)
	};

#undef FF
#undef L

	int64_t ir;
	double fr;

	size_t dsz = MT_SIZEOF(to);
	size_t ssz = MT_SIZEOF(from);
	const void *ld = &&invalid + ld_offset[from & (F+U+SS)];
	const void *st = &&invalid + st_offset[((from & F) >> 1) | (to & (Z+F+SS))];
	goto *ld;

ldi8:   ir = *(int8_t *) src;    goto *st;
ldi16:  ir = *(int16_t *) src;   goto *st;
ldi32:  ir = *(int32_t *) src;   goto *st;
ldi64:  ir = *(int64_t *) src;   goto *st;
ldu8:   ir = *(uint8_t *) src;   goto *st;
ldu16:  ir = *(uint16_t *) src;  goto *st;
ldu32:  ir = *(uint32_t *) src;  goto *st;
ldf32:  fr = *(float *) src;     goto *st;
ldf64:  fr = *(double *) src;    goto *st;

stii8:  *(int8_t *) dest = ir;   goto next;
stii16: *(int16_t *) dest = ir;  goto next;
stii32: *(int32_t *) dest = ir;  goto next;
stii64: *(int64_t *) dest = ir;  goto next;
stif32: fr = (float) ir;         goto stff32;
stif64: fr = (double) ir;        goto stff64;
stiz:   *(int8_t *) dest = !!ir; goto next;
stfi8:  ir = (int8_t) fr;        goto stii8;
stfi16: ir = (int16_t) fr;       goto stii16;
stfi32: ir = (int32_t) fr;       goto stii32;
stfi64: ir = (int64_t) fr;       goto stii64;
stff32: *(float *) dest = fr;    goto next;
stff64: *(double *) dest = fr;   goto next;
stfz:   *(int8_t *) dest = !!fr; goto next;

next:
	if(!--n)
		return 0;
	src += ssz;
	dest += dsz;
	goto *ld;

invalid:
	return MT_ECONV;
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
		case '>': return SIG_RETURN;
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
