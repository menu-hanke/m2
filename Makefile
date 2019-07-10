M2_EXECUTABLE = src/m2

default $(M2_EXECUTABLE):
	$(MAKE) -C src

ffi:
	$(MAKE) -C src ffi

debug:
	$(MAKE) -C src debug

clean:
	$(MAKE) -C src clean
