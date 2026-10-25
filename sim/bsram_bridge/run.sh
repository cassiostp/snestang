#!/bin/sh
# Run on the host: sh run.sh <baseline-snestang_top.v>.
set -eu
DOCKER_RUN=${DOCKER_RUN:-$(command -v simrun >/dev/null 2>&1 && echo simrun || echo "docker run --rm")}
case "$1" in /*) baseline=$1;; *) baseline=$PWD/$1;; esac
cd "$(dirname "$0")"
mkdir -p build
python3 extract.py ../../src/snestang_top.v bridge > build/bridge.v
python3 extract.py "$baseline" bridge_base > build/base.v
python3 extract.py ../../src/snestang_top.v bridge share > build/bridge_share.v
repo=$(cd ../.. && pwd)
$DOCKER_RUN --name "${SIM_PREFIX:-sim$$}_bsram_bridge" \
 --user "$(id -u):$(id -g)" -v "$repo:/w" -w /w/sim/bsram_bridge \
 tangcore-iv:1 sh -c \
 'iverilog -g2012 -DVERILATOR -s tb -o build/bench build/bridge.v build/base.v tb.v && vvp build/bench && iverilog -g2012 -DVERILATOR -DCHIP_SA1 -s tb_share -o build/bench_share build/bridge_share.v ../../src/bwram_256k.v tb_share.v && vvp build/bench_share'
