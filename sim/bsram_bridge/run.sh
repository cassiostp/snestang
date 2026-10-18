#!/bin/sh
# Run on the host: sh run.sh <baseline-snestang_top.v>.
set -eu
case "$1" in /*) baseline=$1;; *) baseline=$PWD/$1;; esac
cd "$(dirname "$0")"
mkdir -p build
python3 extract.py ../../src/snestang_top.v bridge > build/bridge.v
python3 extract.py "$baseline" bridge_base > build/base.v
repo=$(cd ../.. && pwd)
docker run --rm --name "${CONTAINER_PREFIX:-bsram_bridge}_$$" \
 --user "$(id -u):$(id -g)" -v "$repo:/w" -w /w/sim/bsram_bridge \
 tangcore-iv:1 nice -n 10 sh -c \
 'iverilog -g2012 -DVERILATOR -s tb -o build/bench build/bridge.v build/base.v tb.v && vvp build/bench'
