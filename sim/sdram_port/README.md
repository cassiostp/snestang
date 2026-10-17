# SDRAM port bench (`sim/sdram_port`)

Port-level testbench for `src/sdram_cl2_2ch.v` against the behavioral SDRAM
chip from `sim/cosim`. The S-CPU side is driven like `snestang_top` drives
it (ROM/WRAM edge detectors copied from there, 6/8/12-mclk bus cycles),
plus an SA-1-like second master on the CPU2 lane, an SMP-like slow byte
master on the ARAM lane, and a BSRAM probe doing reads and writes.

- `run.sh` — functional regression (all lanes, both S-CPU phases). ARAM
  checks known initial data and later writes with both byte masks and full
  words. Each case must exercise at least 100 reads and writes of each width.
- `run_stable.sh` — proves the two multicycle windows the SDC relies on
  (`src/boards/console138k.sdc`): at every mclk-domain sample the fclk
  data was quiet for >= 3 fclk (SDRAM->SNES, `STABLE` lines), and at every
  controller capture edge (request latch at cycle[0], ARAM latch at
  cycle[2]) every mclk-launched input was older than 1 fclk on the request
  lane with the rotation phase-locked to mclk (`RQSTABLE` lines: no age 0
  or 1, `lock_corr=0`). ARAM's first capture is 1 fclk after launch, so
  its min age (1) is both measured and the enforced setup-1 budget.

Both run in the standard container:

```
docker run --rm --name sdcmc_x --user $(id -u):$(id -g) \
  -v ~/tangcore-work/r5/sdcmc/snestang:/w -w /w/sim/sdram_port \
  tangcore-iv:1 sh run_stable.sh
```
