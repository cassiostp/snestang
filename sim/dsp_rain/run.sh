#!/bin/sh
# DSP rain-scene testbench (Verilator; runs inside verilator/verilator image).
# From the repo: docker run --rm --entrypoint sh --name qa2rain_dsp \
#   --user $(id -u):$(id -g) -v <repo>:/w -w /w/sim/dsp_rain \
#   verilator/verilator:latest run.sh
# (iverilog/Icarus 12 in tangcore-iv:1 cannot compile src/dsp.v's
# unpacked-array localparams, so this sim uses Verilator instead.)
set -e
cd "$(dirname "$0")"
RTL=../../src
rm -rf build
verilator --cc --exe --build -j "$(nproc)" --top-module DSP \
    -I"$RTL" \
    --Mdir build -o Vdsp_rain \
    tb_dsp.cpp "$RTL/dsp.v" "$RTL/CEGen.v"
./build/Vdsp_rain
