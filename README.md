Intro
-----
`m2` is a high-performance branching simulator engine.
It has been developed for the MELA2 forest simulator, but it
should be usable for other similar applications.

`m2` provides a Lua-based scripting environment with automatic
savepoint handling, branch history save & replay (TODO),
and branching-aware data structures.
In addition `m2` comes with an integrated declararive computational graph
library (*fhk*), a pluggable foreign function interface for fhk models
and a small vector-math library.

**The goal of `m2` is to be a low-overhead runtime for MELA2 and related simulators**.
As a rule of thumb, anything that doesn't benefit from being branching-aware will not end up
in the `m2` repository, but should go in a separate library.
(Some exceptions apply, such as *fhk* and *vmath* libraries).

In particular, `m2` is **NOT**
- a general scientific computing environment (whatever that means. just use standard tools and libraries)
- a statistical analysis framework (run your favorite tool, such as R or Python, on simulator output)
- a decision support system (use your favorite method, such as [mathematical optimization](http://mela2.metla.fi/mela/j/jlp.htm), to prune simulator output)
- a forest model or anything forest-related (use MELA2 or one of the numerous [forest decision support systems](http://www.forestdss.org/wiki/index.php?title=Category:DSS)).

Project structure
-----------------
The core is written in C, with a Lua frontend on top.
Below is a brief description of the components.

| Component | Location | Description |
|-----------|----------|-------------|
| core | `sim.c`, `mem.c` | Branching (memory management, record, replay). |
| data structures | `vec.c` | Simulator-memory backed data structures. |
| vector math | `vmath.c` | Small vectorized kernel library (note: this will be replaced with a BLAS/MKL/etc). |
| fhk | `fhk/` | Computational graph solver. |
| fhk foreign functions | `fff/` | A very minimal pluggable FFI for use with fhk. |
| frontend | `frontend/` | Lua environment to glue the libraries together. |

Building
--------

Requirements:
* [LuaJIT v2.1](http://luajit.org/)

Optional dependencies:
* [byuu/libco](https://github.com/creationix/libco): coroutine backend needed to use fhk on
	non-`Linux x86_64` targets. Run `make` with `FHK_CO=libco` (see also `LIBCO_CFLAGS`
	and `LIBCO_LIB`).
* [R](https://www.r-project.org/): support for `R` models. Include `R` in the `FFF_LANG`
	variable when running `make`.

Run `make` to get a release build with all features.
Run `make debug` to get a debug build.
If `pkg-config` is not available may need to edit library paths, see `src/Makefile`.
You can run tests using your favorite TAP harness (for example `prove`).

Windows support is not a primary goal, but it should run under Cygwin.

Getting started
---------------
TODO (I will write a tutorial later). There will also be API docs (some day).

CLI
---
`m2` comes with a simple CLI to start your simulator. See `m2 simulate -h` for details.
