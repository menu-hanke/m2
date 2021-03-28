#include <stdint.h>

#include "signature.h"

int fff_parse_signature(fff_signature *s, const char *sig, const fff_sigtoken *def){
	s->np = 0;
	s->nr = 0;
	uint8_t *n = &s->np;
	uint32_t ep = 0;

	while(*sig){
		if(*sig == ' ' || *sig == ',' || *sig == '\t' || *sig == '\n'){
			sig++;
			continue;
		}

		if(*sig == '>'){
			if(n == &s->nr)
				return -1;
			n = &s->nr;
			sig++;
			continue;
		}

		for(const fff_sigtoken *tok=def; tok->u32; tok++){
			const char *ss = sig;
			const char *t = tok->token;

			for(uint32_t i=0;i<sizeof(*tok);i++,t++,ss++){
				if(!*t) break;
				if(*t != *ss){
					ss++;
					goto next;
				}
			}

			if(ep == sizeof(s->types))
				return -1;
			if(!++(*n))
				return -1;

			s->types[ep++] = tok - def;
			sig = ss;
			goto found;

next:
			continue;
		}

		return -1;

found:
		continue;
	}

	return 0;
}
