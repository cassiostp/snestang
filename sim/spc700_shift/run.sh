#!/bin/sh
# SPC700 shift/rotate regression bench (Verilator; runs inside the
# verilator/verilator image).
# From the repo: simrun --entrypoint sh --name ${SIM_PREFIX:-sim$$}_spcshift \
#   --user $(id -u):$(id -g) -v <repo>:/w -w /w/sim/spc700_shift \
#   verilator/verilator:latest run.sh
# (simrun is an optional local helper; plain `docker run --rm` works too.)
set -e
cd "$(dirname "$0")"
RTL=../../src/spc700
rm -rf build
verilator --cc --exe --build -j "$(nproc)" --top-module SPC700 \
    -I"$RTL" \
    --Mdir build -o Vspc700_shift \
    tb_spc700_shift.cpp \
    "$RTL/_spc700_package.v" "$RTL/addrgen.v" "$RTL/addsub.v" \
    "$RTL/alu.v" "$RTL/bcdadj.v" "$RTL/mcode.v" "$RTL/muldiv.v" \
    "$RTL/spc700.v"
./build/Vspc700_shift
