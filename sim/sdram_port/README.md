# SDRAM port bench (`sim/sdram_port`)

Port-level testbench for `src/sdram_cl2_2ch.v` against the behavioral SDRAM
chip from `sim/cosim`. The S-CPU side is driven like `snestang_top` drives
it (ROM/WRAM edge detectors copied from there, 6/8/12-mclk bus cycles),
plus an SA-1-like second master on the CPU2 lane, an SMP-like slow byte
master on the ARAM lane, and a BSRAM probe doing reads and writes.

- `run.sh` — functional regression (all lanes, both S-CPU phases). ARAM
  checks known initial data and later writes with both byte masks and full
  words. Each case must exercise at least 100 reads and writes of each width.
- `run_stable.sh` — checks the protocol's functional sample windows:
  every ROM/WRAM/CPU2/BSRAM consumer sees data quiet for at least three
  fclk (`STABLE`), requests have reported minimum age two, ARAM requests
  age one, and `lock_corr=0`. The request detector reads the rotated
  cycle bit after the edge, one fclk before the controller's actual latch;
  those measured ages correspond to three and two fclk respectively.
  The console138k SDC additionally constrains cycle[1]/cycle[4] data to
  the first following mclk, two fclk after launch. This bench's functional
  sample check does not measure pin timing; CI checks the SDRAM I/O delays.

Both run in the standard container:

```
simrun --name ${SIM_PREFIX:-sim$$}_sdcmc --user $(id -u):$(id -g) \
  -v ~/tangcore-work/r5/sdcmc/snestang:/w -w /w/sim/sdram_port \
  tangcore-iv:1 sh run_stable.sh
```
