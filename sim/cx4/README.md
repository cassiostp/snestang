# sim/cx4: CX4 (Mega Man X2/X3) testbenches

Two benches for the CX4 in `src/chip/CX4` (srg320's VHDL from SNES_MiSTer,
as the core builds it). There is no full-system CX4 simulation: the cosim
is Verilator, which cannot take the chip's VHDL. Game-level evidence is a
hardware test.

## `tb_cx4.vhd` (GHDL): the chip against known results

Plays the S-CPU bus (SlowROM LoROM cycles, as in `src/cpu.v`) and a
cartridge ROM whose answer time after an address change is the generic
`ROM_DELAY_PS`. Checks, against numbers worked out in the bench (no chip
model involved):

* register file reset values and read-back ($7F40-$7FFF, vector RAM,
  GPRs), and the $6000 data RAM window;
* S-CPU ROM reads through CX4Map's LoROM mapping, banks $00/$01/$80;
* the data ROM: `cx4_drom_pkg.vhd` matches `drom.mif`, and the tables hold
  what their names say (sine at $200, square roots at $100, reciprocals
  at $02, each within 2 LSB of the maths);
* a hand-assembled CX4 program loaded into the cache page and run:
  `RDROM` table lookups, signed 24x24 multiplies (2AAAAAh x 5, -1 x 7
  incl. the MACH sign extension), `WRRAM`, HLT/IRQ and acknowledge,
  read back through $6000;
* the chip's ROM -> data RAM DMA.

```
docker run --rm --name <prefix>_cx4 --user $(id -u):$(id -g) \
  -v <repo>:/w -w /w/sim/cx4 <ghdl image> sh run.sh
```

Needs a GHDL (LLVM) image, e.g. debian with the `ghdl-llvm` package.
`sh run.sh` runs at ROM delays of 0 and 3 master clocks (10 ns each in
bench time). `sh run.sh sweep` maps where the program stops passing over
ROM delay x programmed wait states ($7F50): with the reset value WS=3
the limit is about 3.8 master clocks, with WS>=4 about 4.8. At 5
master clocks the S-CPU's own ROM reads through the mapper fail too
(the mapper latches the CPU address at SYSCLKR_CE and the CPU samples
5 master clocks later).

## `port/tb_port.v` (iverilog): the real SDRAM ROM port at CX4 cadence

The ROM/WRAM request logic extracted from `src/snestang_top.v` at build
time (see `port/run.sh`), the real `sdram_snes` controller, and the
cosim's behavioural SDRAM chip. The CX4 side replays the chip's
cache-fill cadence (CEGen ticks, sample after WS1+1 ticks); an S-CPU
model makes WRAM accesses in a set percentage of SlowROM cycles.

```
docker run --rm --name <prefix>_cx4port --user $(id -u):$(id -g) \
  -v <repo>:/w -w /w/sim/cx4/port tangcore-iv:1 sh run.sh
```

Findings (6000 fetches per run): half the byte fetches are the second
byte of an already-fetched word and answer at once; word-changing
fetches arrive 3.3 or 4.3 master clocks after the address. So a cache
fill run at WS1>=4 with the port to itself is error-free (0/6000),
while the reset WS1=3 corrupts 17% of the bytes. With concurrent WRAM
traffic in 50% of S-CPU cycles, requests are lost to the port's
fire-and-forget toggle (`cpu_req_ack` is unconnected) and both streams
corrupt at any wait-state setting. Whether a game hits either case
depends on the wait states it programs and on what the S-CPU does while
the CX4 is busy; the queued SDRAM arbiter being built for SA-1 is the
fix for the second.
