#!/bin/sh
# SA-1 core sim (GHDL). From this directory:  ./run.sh
# Needs sa1test.hex (mkrom.py, python3) in this directory and the SA-1
# VHDL under ../../src/chip/SA1. Intended docker image: a GHDL one, e.g.
#   simrun -v $PWD/../..:/w -w /w/sim/sa1_core <ghdl-image> sh run.sh
# (simrun is an optional local helper; plain `docker run --rm` works too.)
set -e
cd "$(dirname "$0")"
# GHDL elaborates a 2 MB ROM default value; the container's default 8 MB
# stack is not enough (the run then dies silently with exit 255).
ulimit -s 65536 2>/dev/null || true
if command -v python3 >/dev/null 2>&1; then
    python3 mkrom.py sa1test.hex
fi
test -f sa1test.hex
SA1=../../src/chip/SA1
mkdir -p build && cd build
ghdl -a --std=08 -fsynopsys ../$SA1/P65816_pkg.vhd ../$SA1/BCDAdder.vhd ../$SA1/AddSubBCD.vhd \
    ../$SA1/ALU.vhd ../$SA1/AddrGen.vhd ../$SA1/MCode.vhd ../$SA1/P65C816.vhd \
    ../$SA1/spram.vhd ../$SA1/SA1MULT.vhd ../$SA1/SA1DIV.vhd ../$SA1/SA1.vhd ../$SA1/SA1Map.vhd \
    ../tb_sa1.vhd
ghdl -e --std=08 -fsynopsys tb_sa1
cp ../sa1test.hex .
ghdl -r --std=08 -fsynopsys tb_sa1 --stop-time=60ms > tb_sa1.log 2>&1 || { tail -40 tb_sa1.log; exit 1; }
grep -E 'tb_sa1:|FAIL|wait cycles' tb_sa1.log
grep -q "tb_sa1: PASS" tb_sa1.log
