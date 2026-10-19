#!/bin/sh
# SPPU left-edge sprite sim (Verilator, like sim/cosim's Makefile).
# Runs on the host:  sh sim/ppu_sprite/run.sh
# iverilog cannot parse ppu.v's SystemVerilog, so this uses the verilator
# docker image; -DVERILATOR selects the behavioural OAM/CGRAM in
# ppuoam.v/ppucgram.v. build/ is not committed.
set -e
cd "$(dirname "$0")"
ROOT=$(cd ../.. && pwd)
mkdir -p build
# Runner: simrun when present (persistent ccache + full-core env), else plain docker.
DOCKER_RUN=${DOCKER_RUN:-$(command -v simrun >/dev/null 2>&1 && echo simrun || echo "docker run --rm")};
$DOCKER_RUN --entrypoint sh --name "${PPU_SPRITE_CONTAINER:-${SIM_PREFIX:-sim$$}_ppu_sprite}" \
    --user "$(id -u):$(id -g)" -e HOME=/tmp \
    -v "$ROOT:/w" -w /w/sim/ppu_sprite verilator/verilator:latest -c '
        verilator --binary --timing --top-module tb_ppu_sprite \
            -Mdir build/obj -I../../src -DVERILATOR \
            --public-flat-rw --x-assign 0 --x-initial 0 -Wno-fatal \
            tb_ppu_sprite.sv ../../src/ppu.v ../../src/ppuoam.v ../../src/ppucgram.v \
        && build/obj/Vtb_ppu_sprite'
