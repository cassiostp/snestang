# cx4_boot

Full-system CX4 boot check: Mega Man X2/X3 (the only CX4 games) running on
the whole `snestang_top` Verilator model, with the CX4 converted from its
VHDL (`src/chip/CX4`) to Verilog by GHDL synthesis.

## Layout

- `run.sh` — builds and runs everything (needs docker: a GHDL image for
  the synthesis and `verilator/verilator` for the model; the produced
  binary runs on the host). Usage:
  `sh run.sh build`, then `sh run.sh run <game.sfc> <frames> [outdir]`.
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

## Frame counting

The driver counts SNES frames: `y_out` includes the field bit, so a full
wrap covers two frames. Dumps snap to even frames. Each pair of frames
also reports the number of nonzero pixels in the captured picture.

Set `DUMPS` to a comma-separated list of frames and `CONTAINER_PREFIX` to
an optional container prefix (the default includes the shell PID). `JOBS`
sets the build parallelism. Both controllers default to released buttons.
`INPUT_SCRIPT` optionally names a text file with `frame buttons` rows;
buttons are hexadecimal in `controller_adapter.sv` order (Start is `008`). The simulator uses ideal SDRAM timing; board
timing and HDMI output require hardware checks.

ROMs are never committed: `run.sh` takes a local `.sfc` path and all
ROM-derived outputs stay under `build/` or the specified output directory.
