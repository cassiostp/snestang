# Full-system sim on the real SDRAM controller

`snestang_top` as built for Verilator (138K clocks: fclk = 3 × mclk, rising
edges aligned, `clkref` = `DOT_CLK_CE`), with `CHIP_GSU`, the real
`sdram_snes` (`src/sdram_cl2_2ch.v`) and `sim/cosim/sdram_chip.sv` on its
pins. The smoke suite's behavioural stand-in (`src/verilator/sdram_sim.v`)
is not in this model.

The chip model is cycle-accurate on the controller clock. Hardware clocks
the SDRAM from `fclk_p` (`gowin_pll_snes` CLKOUT2, `PE_COARSE` 19,
`PE_FINE` 3). That shift is what makes CL2 data stable at the controller's
sample (`cycle[4]` on the CPU lane, `cycle[1]` on ARAM). The model presents
the data at that sample; `sim/sdram_port` and `sim/gamesave` wire it the
same way.

The ROM streams through `test_loader` / `smc_parser`, held in reset until
`sdram_busy` falls (the controller's 200 µs init). On hardware the
firmware streams the ROM much later. Capture matches the smoke suite:
per-frame log, PPM dumps, `audio_ready` stereo, BSRAM and ARAM images.

```sh
docker run --rm --name <task>_realsdram --user $(id -u):$(id -g) \
  --entrypoint sh -v <repo>:/w -w /w/sim/realsdram \
  verilator/verilator:latest ./run.sh build
./run.sh run smw game.sfc 600 /tmp/out [script]
```

`run build` is the docker step (Verilator). `run run` is the host binary.
At most a few games at once; a few hundred frames is the useful first
length. CX4 and SA-1 are VHDL and are not in this model.

`tools/smoke/snes/build.sh` builds the same model when `SMOKE_REAL_SDRAM=1`.
