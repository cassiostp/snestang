#!/bin/sh
# S-RTC sims (iverilog): smc_parser decode + time-pack/SRTC reload.
set -eu
cd "$(dirname "$0")"
SRC=../../src
# Runner: simrun when present (persistent ccache + full-core env), else plain docker.
DOCKER_RUN=${DOCKER_RUN:-$(command -v simrun >/dev/null 2>&1 && echo simrun || echo "docker run --rm")};
run() {
    if command -v iverilog >/dev/null 2>&1; then
        sh -c "$1"
    elif docker image inspect tangcore-iv:1 >/dev/null 2>&1; then
        $DOCKER_RUN --user "$(id -u):$(id -g)" -v "$PWD/../..":/w \
            -w /w/sim/srtc tangcore-iv:1 sh -c "$1"
    else
        echo "need iverilog or docker (tangcore-iv:1)" >&2; exit 1
    fi
}
run "iverilog -g2005 -Wall -o tb_smc.vvp $SRC/smc_parser.v tb_smc_srtc.v && vvp tb_smc.vvp" 2>&1 | tee tb_smc.log
grep -q "tb_smc_srtc: PASS" tb_smc.log || { echo "tb_smc_srtc: FAIL"; exit 1; }
rm -f tb_smc.vvp tb_smc.log
run "iverilog -g2005 -Wall -o tb_pack.vvp $SRC/chip/DSP/srtc_time_pack.v tb_srtc_pack.v && vvp tb_pack.vvp" 2>&1 | tee tb_pack.log
grep -q "tb_srtc_pack: PASS" tb_pack.log || { echo "tb_srtc_pack: FAIL"; exit 1; }
rm -f tb_pack.vvp tb_pack.log
