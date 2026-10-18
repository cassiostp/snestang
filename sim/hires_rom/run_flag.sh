#!/bin/sh
# PPU HIGH_RES flag sim (Verilator, like sim/ppu_timing). From the repo:
#   docker run --rm --name <task>_hiresflag --user $(id -u):$(id -g) \
#     -v <repo>:/w -w /w/sim/hires_rom verilator/verilator:latest sh run_flag.sh
set -e
cd "$(dirname "$0")"
ROOT=$(cd ../.. && pwd)
mkdir -p build
docker run --rm --name "${HIRES_FLAG_CONTAINER:-sneshires_hiresflag}" \
    --user "$(id -u):$(id -g)" -e HOME=/tmp \
    -v "$ROOT:/w" -w /w/sim/hires_rom verilator/verilator:latest -c '
        verilator --binary --timing --top-module tb_hires_flag \
            -Mdir build/obj -I../../src \
            --public-flat-rw --x-assign 0 --x-initial 0 -Wno-fatal \
            tb_hires_flag.sv ../../src/ppu.v ../../src/ppuoam.v ../../src/ppucgram.v \
        && build/obj/Vtb_hires_flag'
