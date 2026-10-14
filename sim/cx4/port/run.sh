#!/bin/sh
# Port replay (iverilog): the real ROM/WRAM request logic of snestang_top.v + the real sdram_snes controller
# + the cosim's behavioural SDRAM chip, driven with the CX4's ROM fetch cadence. From the repo:
#   docker run --rm --name <prefix>_cx4port --user $(id -u):$(id -g) -v <repo>:/w -w /w/sim/cx4/port tangcore-iv:1 sh run.sh
# Prints, for several wait states and amounts of S-CPU WRAM traffic, how many CX4 fetches got wrong data.
set -e
cd "$(dirname "$0")"
SRC=../../../src
B=build
rm -rf $B && mkdir -p $B

# the request logic comes straight out of snestang_top.v, so this cannot drift from the core
awk '/\/\/ ROM read and load/ {on=1} /\/\/ BSRAM read\/write/ {on=0} on' $SRC/snestang_top.v > $B/top_req.vh
grep -q "rom_addr_sd != rom_addr" $B/top_req.vh
grep -q "WRAM read/write" $B/top_req.vh
! grep -q "BSRAM" $B/top_req.vh

# same two port-declaration softeners as sim/cosim/Makefile; no functional change
sed -e 's/inout  reg \[15:0\] SDRAM_DQ/inout [15:0] SDRAM_DQ/' \
    -e 's/output reg  \[7:0\] bsram_dout/output [7:0] bsram_dout/' \
    $SRC/sdram_cl2_2ch.v > $B/sdram_snes_sim.v

iverilog -g2012 -I $B -o $B/tb_port.vvp tb_port.v $B/sdram_snes_sim.v ../../cosim/sdram_chip.sv

run() { vvp $B/tb_port.vvp "$@" | grep -v "^VCD\|^WARNING"; }

if [ "$1" = quick ]; then
	run +ws=3 +steps=2000
else
	for ws in 3 4; do
		for wram in 0 50; do
			run +ws=$ws +steps=6000 +wram=$wram
		done
	done
fi
