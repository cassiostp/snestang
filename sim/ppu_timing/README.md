# sim/ppu_timing: PPU scanline and frame timing

`tb_ppu_timing.sv` runs the real SPPU (Verilator) and counts master
clocks per dot, per line and per field, against real NTSC hardware:
1364 clocks per line (dots 323 and 327 are 6 clocks, the rest 4), a
1360-clock short line at V=240 on odd non-interlaced fields, 262-line
frames of 357368/357364 clocks, and 263/262-line interlaced fields
with no short line. Sources: fullsnes "SNES Timing H/V Counters",
ares `sfc/ppu/counter/inline.hpp`, SNES_MiSTer `rtl/PPU.vhd`.

Run (from this directory):

```
sh run.sh
```

Exit code 0 with a `PASS` line means every measured dot, line and
frame length matched.
