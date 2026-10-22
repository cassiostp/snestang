#!/bin/sh
# hires_rom sims. Run on the host (needs python3 and docker). From this directory: ./run.sh
# Assembler: Python3 only (build.py is the assembler, no external tools).
# Rebuilds hires_test.sfc from hires_test.asm and checks the rebuild is
# byte-identical to the committed binary, so the binary can't drift from
# the source; then runs the iverilog scaler bench in tangcore-iv:1
# (tb_hires_flag.sv needs the Verilator image: sh run_flag.sh).
set -e
DOCKER_RUN=${DOCKER_RUN:-$(command -v simrun >/dev/null 2>&1 && echo simrun || echo "docker run --rm")}
cd "$(dirname "$0")"
mkdir -p build
cp hires_test.sfc build/hires_test_committed.sfc
python3 build.py
cmp hires_test.sfc build/hires_test_committed.sfc
echo "ROM rebuild identical to committed binary"
$DOCKER_RUN --name "${HIRES_ROM_CONTAINER:-${SIM_PREFIX:-sim$$}_hires_rom}" \
    --user "$(id -u):$(id -g)" -v "$(cd ../.. && pwd):/w" -w /w/sim/hires_rom \
    tangcore-iv:1 sh -c 'iverilog -g2012 -I../../src/variant/standard -o tb_hires_rom.out tb_hires_rom.v ../../src/snes2hdmi.v ../../src/scanlines.v ../../src/video_fx.v ../../src/dual_clk_fifo.v ../scanlines/hdmi_stub.v && vvp tb_hires_rom.out'
