#!/bin/sh
set -e
cd "$(dirname "$0")"
verilator --binary --timing -j "${JOBS:-$(nproc)}" -Wno-fatal --top-module tb_gsu_multiply --Mdir build \
    tb_gsu_multiply.sv ../../src/chip/GSU/GSU_PKG.v ../../src/chip/GSU/GSU.v
./build/Vtb_gsu_multiply
