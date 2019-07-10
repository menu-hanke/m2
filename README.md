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

Example: solve `y` from given data in `examples/basic_xc.csv` and save results to `out.txt`
```
m2 -F -c examples/config.lua -i examples/basic_xc.csv -f y -o out.txt
```
