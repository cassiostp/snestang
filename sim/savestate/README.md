# SNES save-state simulation

The bench uses `sim/realsdram`: the full SNES machine, real CL2 SDRAM controller, behavioral SDRAM chip, BRAM VRAM and the production state transport. The test drives the state byte interface directly; `sim/cosim` separately exercises the UART interface with firmware.

Build from `sim/realsdram` inside the Verilator image with `SS_TEST_SOURCE=/w/sim/savestate/check.cpp ./run.sh build`. Use `make_rom.py` to prepare a local game's `roms/game.hex` in a private run directory, copy the DSP hex tables there, then run the model with a boot-clock count. ROMs and all derived output stay local. The test compares video/audio every master clock and WRAM/ARAM/BSRAM after save/continue versus reset/load/continue. It also compares endpoint image offsets for debugging. The default boot interval is 100 million master clocks.

The register image uses a disjoint byte bus through the machine. `src/ss_map.json` lists the generated scalar/array slices. Additional pages are CGRAM at 0x1e00, OAM at 0x1c00, BRAM/SDRAM output latches at 0x1b30..0x1b4b, CPU microcode at 0x1b50..0x1b5b, and machine-side memory bridge state at 0x1b60..0x1b92. Format version must change if any image offset changes. ROM identity/CRC validation belongs to the firmware; the FPGA rechecks the header before reset.

Only base-console cartridges advertise support. DSPn, S-RTC, OBC-1, SA-1, GSU and CX4 are refused until their complete state ports are available. The feature is absent from 60K synthesis.

Full-byte scalar fields use three circular byte scan chains while frozen. A
512-byte snapshot RAM and a synchronous sparse-address ROM replace their read
muxes and per-byte write decode. Partial fields, audio/video outputs and the
DSP RAM ports retain their existing hooks. The register image addresses and
layout version remain unchanged. Capture ready follows a complete rotation;
end/abort waits for an in-progress rotation before releasing the machine.

`sh sim/savestate/run_scan.sh` checks all 8192 sparse bytes, continuous register
loads and mid-scan aborts against synthetic byte chains. For the full-game
model, set `SS_SCAN_VERIFY=1` as well as `SS_TEST_SOURCE`: this compares each
snapshot byte with the original read expressions retained only in simulation.
