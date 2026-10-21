# sa1_boot

Full-system SA-1 boot sim: Kirby Super Star (the only SA-1 game in the test
bundle) running on the whole `snestang_top` Verilator model, with the SA-1
converted from its VHDL (`src/chip/SA1`) to Verilog by GHDL synthesis. This
is the sim that showed the Kirby intro logos render (Mode 7) with clean
tiles in VRAM: the vertical bars of round-5 hardware do not reproduce under
ideal SDRAM timing, pointing at hardware timing (see the kirby report).

## Layout

- `run.sh` — builds and runs everything (needs docker: a GHDL image for
  the synthesis and `verilator/verilator` for the model; the produced
  binary runs on the host). Usage:
  `sh run.sh build` then `sh run.sh <game.sfc> <frames> [outdir]`.
- `synth_fixup.py` — mechanical fixups for GHDL 5.0.1's
  `--out=verilog` output so iverilog/Verilator accept it: lowercase
  identifiers (the tree binds the `SA1Map` ports lowercase, except `.DO`),
  drop the duplicate `wire` declarations GHDL emits. Needs `--latches`
  (the SA-1 CPU core infers latches, like the Gowin build) and
  `-Wno-UNOPTFLAT -Wno-LATCH` on the Verilator command line (sim-only;
  Gowin never sees this file).
- `tb_sa1_boot.cpp` — headless driver: streams the ROM through the real
  loader/`smc_parser` path, prints a periodic S-CPU trace, dumps PPM
  frames at the requested list, and offers state probes:
  `-s <frame>` dumps VRAM (both banks), CGRAM, SA-1 IRAM and BW-RAM,
  OAM + high table, and prints the PPU background/Mode-7 registers;
  `-pxtrace <vcnt>` logs the Mode-7 fetch pipeline per mclk for one line.
  Also includes the smoke joypad shim (standard pad, no buttons, on port
  1; port 2 disconnected): without it both `JOY_DI` lines float at 0 and
  Kirby waits on its multitap/mouse warning screen.
- `test_loader.v` — ROM streamer (identical to the smoke loader).
- `build/` (git-ignored) — the synthesized Verilog, the model, runs.

## What it showed (Kirby Super Star (USA), SA-1 LoROM, rom_type 0x63)

- Boots through the Nintendo/HAL logo screens (Mode 7) to the title and
  into gameplay; frames dumped through the intro.
- Logo tiles arrive via S-CPU DMA ROM (`00:FFFE+`, 0x2000 bytes at
  ~16.8M mclk) → WRAM (`$7E:2000+`) → VRAM (`$2118/19`, from ~46.6M).
  No SA-1 character-conversion or BW-RAM traffic feeds them (two tiny
  S-CPU reads touch SA-1 IRAM for OAM/OBSEL setup only).
- VRAM tiles/map, CGRAM and the Mode-7 matrices decode clean; an
  independent Python Mode-7 reference render from the dumped state shows
  no bars. The sim is clean: no SA-1 logic bug reproduced.
- The SA-1 is ROM-active throughout the upload (`sa1_rom_req` toggling),
  on its own CPU2 lane (`sa1_rom_cache`); the S-CPU ROM reads share the
  single-toggle `cpu_req` lane with WRAM (the cx4hw drop mechanism), so a
  phasing-dependent drop on hardware remains the lead for the HW bars.

ROMs are never committed: `run.sh` takes a local `.sfc` path and all
ROM-derived outputs stay under `build/` (or the chosen outdir).

`VERILATOR_THREADS` is a build-time setting (default 1): the compiled model and runtime thread pool use the same count. Rebuild after changing it; `VERILATOR_THREADS=1` retains the single-thread path.
