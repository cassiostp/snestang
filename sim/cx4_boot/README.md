# cx4_boot

Full-system CX4 boot check: Mega Man X2/X3 (the only CX4 games) running on
the whole `snestang_top` Verilator model, with the CX4 converted from its
VHDL (`src/chip/CX4`) to Verilog by GHDL synthesis. This is the sim that
showed why Mega Man X3 never started (see the `fix/cx4-hw` commits): the
game's boot bulk-fill of CX4 space collaterally starts a DMA with stale
registers, suspends via `$7F55` and starts the CPU before its `$7F48`,
and its table walk reads past mapped ROM.

## Layout

- `run.sh` — builds and runs everything (needs docker: a GHDL image for
  the synthesis and `verilator/verilator` for the model; the produced
  binary runs on the host). Usage:
  `sh run.sh <game.sfc> <frames> [outdir]`.
- `synth_fixup.py` — mechanical fixups for GHDL 5.0.1's
  `--out=verilog` output so iverilog/Verilator accept it: lowercase
  identifiers (the tree binds the `CX4Map` ports lowercase, except `.DO`),
  drop the duplicate `wire` declarations and the `assign x = x`
  self-drivers GHDL emits for the RAM-output signals (they simulate as X
  against the RAM outputs), keep the module name `CX4Map`.
- `tb_cx4_boot.cpp` — headless driver: streams the ROM through the real
  loader/`smc_parser` path, prints a periodic S-CPU/CX4 trace plus a PC
  histogram, dumps PPM frames at the requested list.
- `build/` (git-ignored) — the synthesized Verilog, the model, runs.

## What it showed (Mega Man X3, 2 MB)

- Before `fix/cx4-hw`: the CX4 sits `busy` forever on a DMA whose dest
  selects nothing (started with stale regs by the boot fill) under a
  latched `SUSPEND`, while the CPU idles on an empty cache; the S-CPU
  parks and the screen stays black.
- After: the CX4 runs the boot program from `02:8000`, halts, the S-CPU
  proceeds, and the title/intro frames draw.

ROMs are never committed: `run.sh` takes a local `.sfc` path and all
ROM-derived outputs stay under `build/`.
