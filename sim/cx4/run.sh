#!/bin/sh
# CX4 chip testbench (GHDL). From the repo, with any ghdl image (the --name is yours to choose):
#   docker run --rm --name <prefix>_cx4 --user $(id -u):$(id -g) -v <repo>:/w -w /w/sim/cx4 <ghdl image> sh run.sh
# The chip is srg320's CX4Map/CX4 as the core builds them (src/chip/CX4). tb_cx4.vhd plays the S-CPU
# bus and the ROM port and checks the chip against known results; see its header.
#   sh run.sh            the checks with an ideal ROM port and with one that answers in 3 master clocks
#   sh run.sh sweep      how slow can the ROM port be: ROM_DELAY 0..7 master clocks x wait states 1..7
set -e
cd "$(dirname "$0")"
CHIP=../../src/chip/CX4
W=build
rm -rf $W && mkdir -p $W
OPTS="--std=08 -frelaxed -fsynopsys --workdir=$W"
ghdl -a $OPTS $CHIP/CEGen.vhd $CHIP/cx4_drom_pkg.vhd $CHIP/spram.vhd $CHIP/dpram_difclk.vhd \
	$CHIP/cx4cache.vhd $CHIP/CX4.vhd $CHIP/CX4Map.vhd tb_cx4.vhd 2>&1 | grep -v "shared\|\^" || true

run() {  # run <rom_delay in ps> <ws>
	ghdl --elab-run $OPTS tb_cx4 -gROM_DELAY_PS=$1 -gWS=$2 --stop-time=60ms 2>&1 | grep -v "metavalue\|^$\|numeric_std"
}

if [ "$1" = sweep ]; then
	printf "program passes (P) or fails (-); rows: ROM_DELAY in master clocks, columns: wait state WS1=WS2\n"
	printf "%8s" ""; for ws in 1 2 3 4 5 6 7; do printf " WS=%d" $ws; done; echo
	for d in 0 10 20 25 30 32 34 36 38 40 42 44 46 48 50 55 60 70; do
		printf "%5s ns" $d
		for ws in 1 2 3 4 5 6 7; do
			if run "$((d * 1000))" $ws | grep -q "report note): PASS"; then printf "   P  "; else printf "   -  "; fi
		done
		echo
	done
else
	run 0 -1
	run 30000 -1
fi
