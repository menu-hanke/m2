m2
===

**NOTE:** This is in very experimental state and will crash with wrong inputs etc.

Building
--------
Install `luajit` and `R` and modify the paths in Makefile if needed.

Run `make` or `make debug` to build and you will get an executable in `src/m2`.

Running
-------
For all command line switches see `src/lua/m2.lua`.

### Fhk debugger
Use the `fhkdbg` command to have fhk explain your graph to you:
```
m2 fhkdbg -c <config> -i <input csv> -f <solve>
```

For example, solve `y` from `examples/basic_xc.csv`:

```
m2 fhkdbg -c examples/config.lua -i examples/basic_xc.csv -f y
```

### Simulation
Use the `simulate` command, or leave out the command (`simulate` is the default) to run a simulation:
```
m2 -c <config> [-s <script>]+
```

To run the simulation example:

```
m2 -c examples/config.lua -s examples/sim_events.lua -s examples/sim_script.lua
```