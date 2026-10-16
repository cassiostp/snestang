# sim/scpu_timing: S-CPU refresh stall and IRQ/HDMA positions

`tb_scpu_timing.sv` runs the real SCPU (Verilator) on a NOP sled with
a synthetic 262-line frame and checks the WRAM-refresh stall against
real hardware: one 40-master-clock stall per scanline (fullsnes
"SNES Timing H/V Counters"; ares `sfc/cpu/timing.cpp`). It also
reports the master-clock positions, from line start, of H-IRQ for
several HTIME values and of the HDMA trigger (hardware: dot 276,
clock 1104) for comparison.

Run (from this directory):

```
sh run.sh
```

Exit code 0 with a `PASS` line means the refresh count and width
matched in every measured frame.
