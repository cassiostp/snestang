#!/bin/sh
# PPU line/frame timing sim (Verilator, like sim/ppu_sprite).
# Runs on the host:  sh sim/ppu_timing/run.sh
set -e
cd "$(dirname "$0")"
ROOT=$(cd ../.. && pwd)
mkdir -p build
# Runner: simrun when present (persistent ccache + full-core env), else plain docker.
DOCKER_RUN=${DOCKER_RUN:-$(command -v simrun >/dev/null 2>&1 && echo simrun || echo "docker run --rm")};
$DOCKER_RUN --entrypoint sh --name "${PPU_TIMING_CONTAINER:-${SIM_PREFIX:-sim$$}_snesline_ppu_timing}" \
    --user "$(id -u):$(id -g)" -e HOME=/tmp \
    -v "$ROOT:/w" -w /w/sim/ppu_timing verilator/verilator:latest -c '
        verilator --binary --timing --top-module tb_ppu_timing \
            -Mdir build/obj -I../../src -DVERILATOR \
            --public-flat-rw --x-assign 0 --x-initial 0 -Wno-fatal \
            tb_ppu_timing.sv ../../src/ppu.v ../../src/ppuoam.v ../../src/ppucgram.v \
        && build/obj/Vtb_ppu_timing'
