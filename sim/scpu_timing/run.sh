#!/bin/sh
# S-CPU refresh/IRQ/HDMA timing sim (Verilator, like sim/ppu_sprite).
# Runs on the host:  sh sim/scpu_timing/run.sh
set -e
cd "$(dirname "$0")"
ROOT=$(cd ../.. && pwd)
mkdir -p build
# Runner: simrun when present (persistent ccache + full-core env), else plain docker.
DOCKER_RUN=${DOCKER_RUN:-$(command -v simrun >/dev/null 2>&1 && echo simrun || echo "docker run --rm")};
$DOCKER_RUN --entrypoint sh --name "${SCPU_TIMING_CONTAINER:-${SIM_PREFIX:-sim$$}_snesline_scpu_timing}" \
    --user "$(id -u):$(id -g)" -e HOME=/tmp \
    -v "$ROOT:/w" -w /w/sim/scpu_timing verilator/verilator:latest -c '
        verilator --binary --timing --top-module tb_scpu_timing \
            -Mdir build/obj -I../../src -DVERILATOR \
            --public-flat-rw --x-assign 0 --x-initial 0 -Wno-fatal \
            tb_scpu_timing.sv ../../src/cpu.v \
            ../../src/65C816/common.sv ../../src/65C816/mcode.sv \
            ../../src/65C816/ALU.v ../../src/65C816/AddSubBCD.v \
            ../../src/65C816/AddrGen.v ../../src/65C816/BCDAdder.v \
            ../../src/65C816/P65C816.v ../../src/65C816/adder4.v \
            ../../src/65C816/bit_adder.v \
        && build/obj/Vtb_scpu_timing'
