#pragma once

//---- memory ----------------------------------------
// map above 2gb to let luajit have the lower 2gb
#define VM_MAP_ABOVE               0x100000000ULL
#define VM_PROBE_RETRIES           10

//---- simulation ----------------------------------------
#define SIM_SAVEPOINT_BLOCKSIZE    64

// alignment for bulk allocs (eg. vector ops)
#define SIMD_ALIGN_HINT            16
