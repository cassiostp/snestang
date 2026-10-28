#!/bin/sh
# Run on the host: sh run.sh [DELAY ...]  (default: 3)
# Extracts the real bridge from src/snestang_top.v (via the
# bsram_bridge extractor) and sweeps enable-low windows against
# GSU/S-CPU BSRAM accesses with save-channel traffic streaming.
set -eu
DOCKER_RUN=${DOCKER_RUN:-$(command -v simrun >/dev/null 2>&1 && echo simrun || echo "docker run --rm")}
cd "$(dirname "$0")"
mkdir -p build
python3 ../bsram_bridge/extract.py ../../src/snestang_top.v bridge > build/bridge.v
repo=$(cd ../.. && pwd)
delays="${*:-1 2 3}"
cmd='iverilog -g2012 -DVERILATOR -s tb -o build/bench build/bridge.v tb.v'
for d in $delays; do cmd="$cmd && vvp build/bench +DELAY=$d"; done
$DOCKER_RUN --name "${SIM_PREFIX:-sim$$}_gsu_save_halt" \
 --user "$(id -u):$(id -g)" -v "$repo:/w" -w /w/sim/gsu_save_halt \
 tangcore-iv:1 sh -c "$cmd"
