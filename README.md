m2
===
Branching simulator engine. WIP.

Building
--------

Requirements:
* LuaJIT v2.1   

Optional:
* libco: for `libco` coroutine backend. This is the only backend for targets other than x86_64 Linux.
* R: support for R models.
* libffi: support for SIMO models.

Run `make` or `make debug` to build.
If `pkg-config` is not available may need to edit library paths, see `src/Makefile`.
You can run tests using your favorite TAP harness (for example `prove`).

### Building on Windows

No MinGW support currently, you need Cygwin. Build with
`make FHK_CO=libco`. You probably need to tweak library flags in `src/Makefile`.

Usage
-------
For all command line switches see `src/frontend/m2.lua`.

### Simulation
Use the `simulate` command to run a simulation. See `m2 simulate -h` for options.