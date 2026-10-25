# SNES save-state simulation

The bench uses `sim/realsdram`: the full SNES machine, real CL2 SDRAM controller, behavioral SDRAM chip, BRAM VRAM and the production state transport. The test drives the state byte interface directly; `sim/cosim` separately exercises the UART interface with firmware.

Build from `sim/realsdram` inside the Verilator image with `SS_TEST_SOURCE=/w/sim/savestate/check.cpp ./run.sh build`. Use `make_rom.py` to prepare a local game's `roms/game.hex` in a private run directory, copy the DSP hex tables there, then run the model with a boot-clock count. ROMs and all derived output stay local. The test compares video/audio every master clock and WRAM/ARAM/BSRAM after save/continue versus reset/load/continue. It also compares endpoint image offsets for debugging. The default boot interval is 100 million master clocks.

The register image uses a disjoint byte bus through the machine. `src/ss_map.json` lists the generated scalar/array slices. Additional pages are CGRAM at 0x1e00, OAM at 0x1c00, BRAM/SDRAM output latches at 0x1b30..0x1b4b, CPU microcode at 0x1b50..0x1b5b, and machine-side memory bridge state at 0x1b60..0x1b92. Format version must change if any image offset changes. ROM identity/CRC validation belongs to the firmware; the FPGA rechecks the header before reset.

Only base-console cartridges advertise support. DSPn, S-RTC, OBC-1, SA-1, GSU and CX4 are refused until their complete state ports are available. The feature is absent from 60K synthesis.

`sh sim/savestate/run_capture.sh` (on the host, with `simrun`) compares the
controller's restored output latches against 292d641. It checks all seven image
bytes, proves restore writes leave the raw DQ registers unchanged, and compares
running consumers at their mclk sample edges over repeated save/restore/read
sequences. The read forecast is registered one fclk before the mclk preceding
capture; the override select changes on that mclk and the raw data arrives one
fclk later, before the next consumer edge. Forecast paths use ordinary one-fclk
setup/hold checks; the selects use ordinary mclk timing.
