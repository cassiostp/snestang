# Full-system sim on the real SDRAM controller

`snestang_top` as built for Verilator (138K clocks: fclk = 3 × mclk, rising
edges aligned, `clkref` = `DOT_CLK_CE`), with `CHIP_GSU`, the real
`sdram_snes` (`src/sdram_cl2_2ch.v`) and `sim/cosim/sdram_chip.sv` on its
pins. The smoke suite's behavioural stand-in (`src/verilator/sdram_sim.v`)
is not in this model.

The chip model is cycle-accurate on the controller clock. Hardware clocks
the SDRAM from the phase-shifted `fclk_p` (`gowin_pll_snes` CLKOUT2).
The model presents CL2 data at the controller sample (`cycle[4]` on the
CPU lane, `cycle[1]` on ARAM); `sim/sdram_port` and `sim/gamesave` wire it
the same way. It checks logical read timing, not pin setup/hold or the PLL
phase window; those require static timing with the pin constraints.

The ROM streams through `test_loader` / `smc_parser`, held in reset until
`sdram_busy` falls (the controller's 200 µs init). On hardware the
firmware streams the ROM much later. Capture matches the smoke suite:
per-frame log, PPM dumps, `audio_ready` stereo, BSRAM and ARAM images.

```sh
simrun --name ${SIM_PREFIX:-sim$$}_realsdram --user $(id -u):$(id -g) \
  -e VERILATOR_THREADS=1 --entrypoint sh -v <repo>:/w -w /w/sim/realsdram \
  verilator/verilator:latest ./run.sh build
./run.sh run smw game.sfc 600 /tmp/out [script]
```

`run build` is the docker step (Verilator). `run run` is the host binary.
At most a few games at once; a few hundred frames is the useful first
length. CX4 and SA-1 are VHDL and are not in this model.

Set `VERILATOR_THREADS` at build time to select the model and its runtime
pool together; pass it explicitly with Docker `-e` when using `simrun`.
The default is one thread; rebuild with `VERILATOR_THREADS=1` for that path.
`python3 thread-bench.py <ROM> <new-local-output-dir> --frames 600` measures
1/2/4/8 threads, captures every console frame and compares all captured PPMs,
audio, BSRAM, ARAM and per-frame logs byte for byte. Build/run wall times and
identity results go to `measurements.json`; a byte difference fails the
command. Keep the output directory and all ROM-derived files local.

Set `DUMP_ALL_FRAMES=1` on the run command to save every console frame
through the frame budget as `<game>_c1.ppm` ... `<game>_c600.ppm`.
`C` log records mark every visible-Y wrap and include mclk and audio-sample
counts. The inherited `F` records and `_f60/_f300/_f600` images use a
two-field counter; that counter still drives scripts, preserving input
timing. Compare `C` records, all `_c` images and DSP audio for complete
frame-by-frame coverage. Keep all output local.

The 256-column capture uses `X_OUT[8:1]` (`X_OUT[0]` is `DOT_CLK`)
and decodes the PPU output as BGR555: bits 4:0 are red, 9:5 green,
14:10 blue. These games use one captured sample per horizontal dot.

`REALSDRAM_BUILD` selects the build/run scratch directory (default `build/` beside `run.sh`; relative paths resolve there). The thread benchmark uses a private build directory per thread count so it can run alongside the regular regression without replacing that model.
