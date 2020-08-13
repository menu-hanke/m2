CC = gcc

# Compiler options
CCOPT    = -O3 -flto -fopenmp -ffast-math -march=native
CCDEBUG  = -DNDEBUG
CCDEF    =
CCWARN   = -Wall -Wextra
CCEXTRA  =
XCFLAGS  ?= 
XLDFLAGS ?= 

# -fstack-protector causes about ~10% slowdown for typical fhk graphs.
# Turn it on if you're scared of hackers.
FHK_CCOPT = $(CCOPT) -fno-lto -fno-stack-protector

# What model languages do you want to build in? You can choose any from the following:
# * R      Call R models (requires libR)
# * SimoC  Call SIMO C-models (requires libffi)
# * Lua    Call Lua models (LuaJIT). Note: these run in a different lua state than the simulator.
MODEL_LANG        ?= R SimoC Lua

# Build coroutine support for fhk solver (requires libaco)?
# This allows virtual variables to be written in Lua.
USE_COROUTINES    ?= on

# Where to find/install the frontend lua files?
LUAPATH           ?= $(abspath frontend)

# Library options
LUAJIT_CFLAGS     ?= $(shell pkg-config --cflags luajit)
LUAJIT_LIB        ?= $(shell pkg-config --libs luajit)
R_CFLAGS          ?= $(shell pkg-config --cflags libR)
R_LIB             ?= $(shell pkg-config --libs-only-l --libs-only-L libR)
LIBFFI_CFLAGS     ?= $(shell pkg-config --cflags libffi)
LIBFFI_LIB        ?= $(shell pkg-config --libs libffi)
LIBACO_CFLAGS     ?= -I$(shell realpath ../libaco)
LIBACO_LIB        ?= -Wl,-rpath=$(shell realpath ../libaco) -L$(shell realpath ../libaco) -laco

# You probably don't want to configure anything below this line

################################################################################

M2_EXECUTABLE = m2
M2_LIBS       = $(LUAJIT_LIB)

M2_O = sim.o bitmap.o mem.o grid.o vec.o vmath.o vgrid.o\
	   fhk/solve.o fhk/build.o fhk/reduce.o fhk/debug.o\
	   frontend/main.o frontend/fhk/driver.o frontend/fhk/mapping.o
M2_C = $(M2_O:.o=.c)

MODEL_O = model/mlib.o model/conv.o model/model_Const.o
MODEL_C = $(MODEL_O:.o=.c)

ifneq (,$(findstring Lua,$(MODEL_LANG)))
	MODEL_O += model/model_Lua.o
endif

# ifneq (,$(findstring R,$(MODEL_LANG)))
# 	MODEL_O += model/model_R.o
# 	M2_LIBS += $(R_LIB)
# endif
# 
# ifneq (,$(findstring SimoC,$(MODEL_LANG)))
# 	MODEL_O += model/model_SimoC.o
# 	M2_LIBS += $(LIBFFI_LIB) -ldl
# endif

################################################################################

# TODO: this is only needed for fhk. when fhk uses the custom swap (on x86_64), enable this
# conditionally for non-x86_64
CCEXTRA += $(LIBACO_CFLAGS)
M2_LIBS += $(LIBACO_LIB)

CCDEF += -DM2_LUAPATH='"$(LUAPATH)"'
CFLAGS = $(LUAJIT_CFLAGS) $(CCOPT) $(CCDEBUG) $(CCDEF) $(CCWARN) $(CCEXTRA) $(XCFLAGS)
FHK_CFLAGS = $(FHK_CCOPT) $(CCDEBUG) $(CCDEF) $(CCWARN) $(XCFLAGS)

# -rdynamic is needed to access C symbols of the executable from lua
# Note: GCC docs said I don't need to pass -f parameters again to linker,
# but I can't get it to do lto without passing them.
LDFLAGS = -rdynamic $(M2_LIBS) $(CCDEBUG) $(CFLAGS) $(XLDFLAGS)

################################################################################

default: $(M2_EXECUTABLE) frontend/m2_cdef.lua

valgrind: CCOPT = -g3 -O3 -march=x86-64 -fopenmp -flto -ffast-math
valgrind: default

debug: CCOPT = -g3 -fopenmp
debug: CCDEBUG = -DDEBUG -DFHK_DEBUG
debug: default

ubsan: CC = clang
ubsan: CCOPT = -g3 -O3 -march=native -fopenmp -flto -ffast-math -fsanitize=undefined -fsanitize=address
ubsan: CCWARN += -Wno-c++17-extensions -Wno-gnu-alignof-expression
ubsan: CCDEBUG = -DDEBUG -DFHK_DEBUG
ubsan: default

dep:
	$(CC) $(CCOPT) $(CCDEBUG) $(CCDEF) $(XCFLAGS) -MM *.c fhk/*.c model/*.c frontend/*/**.c \
		| sed -r 's|^(.*\.o:) (.*?)\.c|\2.o: \2.c|'\
		> Makefile.dep
	$(CC) $(CCOPT) $(CCDEBUG) $(CCDEF) $(XCFLAGS) -MM -MT frontend/m2_cdef.lua frontend/m2_cdef.lua.h\
		>> Makefile.dep

frontend/m2_cdef.lua: frontend/m2_cdef.lua.h
	cd frontend && $(CC) $(CCDEF) $(CCDEBUG) -P -E -nostdinc - <m2_cdef.lua.h 2>/dev/null >m2_cdef.lua; true

# you could pipe the preprocessed source through luajit -b
# to generate bytecode, byte it's not much smaller than the source
%.lua.in: %.lua.h
	$(CC) $(CCDEF) $(CCDEBUG) -P -E -nostdinc - <$< 2>/dev/null\
		| xxd -i\
		> $@
	echo ",0x00" >> $@

clean:
	$(RM) $(M2_EXECUTABLE) frontend/m2_cdef.lua model/*.in *.o */**.o

.PHONY: default valgrind debug ubsan dep clean

################################################################################

include Makefile.dep

$(M2_EXECUTABLE): $(M2_O) $(MODEL_O)
	$(CC) $(LDFLAGS) $^ -o $@

%.o: %.c
	$(CC) $(CFLAGS) -c $< -o $@

fhk_solve.o: fhk_solve.c
	$(CC) $(FHK_CFLAGS) -c $< -o $@

model/model_R.o: model/model_R.c
	$(CC) $(CFLAGS) $(R_CFLAGS) -c $< -o $@

model/model_SimoC.o: model/model_SimoC.c
	$(CC) $(CFLAGS) $(LIBFFI_CFLAGS) -c $< -o $@

model/model_Lua.o: model/model_Lua.c
	$(CC) $(CFLAGS) -c $< -o $@
