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

## `port/tb_port.v` (iverilog): the CX4 on the CPU2 lane at CX4 cadence

The ROM/WRAM request logic extracted from `src/snestang_top.v` at build
time (see `port/run.sh`), the real `sdram_snes` controller with both CPU
lanes, the real `sa1_rom_cache` word cache (second instance, as the CX4
uses it), and the cosim's behavioural SDRAM chip. The CX4 side replays the
patched chip's cache-fill cadence (CEGen ticks, sample after WS1+1 ticks,
held while `ROM_WAIT` is up); an S-CPU model makes WRAM accesses in a set
percentage of SlowROM cycles.

```
docker run --rm --name <prefix>_cx4port --user $(id -u):$(id -g) \
  -v <repo>:/w -w /w/sim/cx4/port tangcore-iv:1 sh run.sh
```

Findings (6000 fetches per run, plus a few fully-checked drain fetches): the CX4's own fetches ride CPU2 through
the cache while the S-CPU lane keeps WRAM (and S-CPU ROM while the CX4 is
idle), so the two streams can no longer cancel each other, and the CX4
waits for each word. All of WS1=0..4 and 7 are error-free with and without WRAM
traffic (0 wrong, 0 lost requests, 0 wrong WRAM reads); half the
byte fetches hit the cached word at once, the rest arrive after the
cache fetch (about 1 mclk on hits, longer on misses, longer still at
WS1=1 where the chip outruns the fetch). Before the fix this bench showed
17% corrupt bytes at the reset WS1=3 even alone, and 21-31% corrupt plus
lost requests and lost WRAM writes with concurrent traffic at any wait
state.
