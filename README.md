m2
===
Branching simulator engine. WIP.

Building
--------

Requirements:
* LuaJIT
* libaco
* (optional) R - to call R models (TODO)
* (optional) libffi - to call SIMO models (TODO)

Run `make` or `make debug` to build.
You can run tests using your favorite TAP harness (for example `prove`).

Usage
-------
For all command line switches see `src/lua/m2.lua`.

### Simulation
Use the `simulate` command to run a simulation. See `m2 simulate -h` for options.