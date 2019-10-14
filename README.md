m2
===

Forest simulation framework. No docs yet, see the `examples` directory for help.

Building
--------

Requirements:
* LuaJIT
* (optional) R - to call R models
* (optional) libffi - to call SIMO models
* (optional) libaco - allow Lua side fhk virtuals

Run `make` or `make debug` to build.
You can run tests using your favorite TAP harness (for example `prove`).

Usage
-------
For all command line switches see `src/lua/m2.lua`.

### Simulation
Use the `simulate` command, or leave out the command (`simulate` is the default) to run a simulation:
```
m2 -c <config> -I <instructions> [-i <input>] [-s <script>]+
```

For example:

```
m2 -c examples/config_cal.lua -i examples/plots.json -I examples/instr_grow.lua -s examples/sim_trees_cal.lua
```

### Calibration
Use the `calibrate` command to calibrate a simulator using the Nelder-Mead method:
```
m2 calibrate -c <config> -i <calibration data> -C <calibrator> -p <parameters> [-s <script>]+
```

For example:
```
m2 calibrate -c examples/config_cal.lua -i examples/plots.json -s examples/sim_trees_cal.lua -p examples/opt_c0.json -C examples/calibrate_treesim.lua
```

### Fhk debugger
Use the `fhkdbg` command to have fhk explain your graph to you:
```
m2 fhkdbg -c <config> -i <input csv> -f <solve>
```

For example:

```
m2 fhkdbg -c examples/config_fhktest.lua -i examples/cyclic_ab.csv -f d
```