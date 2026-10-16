#!/bin/sh
# GSU frame-halt freeze sim (Verilator; runs inside verilator/verilator image).
# From the repo: docker run --rm --entrypoint sh --name <task>_gsu \
#   --user $(id -u):$(id -g) -v <repo>:/w -w /w/sim/gsu_halt \
#   verilator/verilator:latest run.sh
# (Icarus 12 cannot compile GSU_PKG.v's unpacked structs, as with dsp_rain.)
set -e
cd "$(dirname "$0")"
RTL=../../src/chip/GSU
rm -rf build
verilator --cc --exe --build -j "$(nproc)" --top-module GSU \
    --Mdir build -o Vgsu_halt \
    tb_gsu_halt.cpp "$RTL/GSU_PKG.v" "$RTL/GSU.v"
echo "-- halt held (ENABLE follows the halt)"
./build/Vgsu_halt > tb_gsu_halt.log && grep -E '^run:|^halt|^resumed:|PASS|FAIL' tb_gsu_halt.log
grep -q "tb_gsu_halt: PASS" tb_gsu_halt.log
echo "-- free-run control (the old ENABLE=1 tie)"
./build/Vgsu_halt +FREE > tb_gsu_halt_free.log && grep -E '^run:|^halt|^resumed:|PASS|FAIL' tb_gsu_halt_free.log
grep -q "tb_gsu_halt: PASS" tb_gsu_halt_free.log
