# SNES co-simulation (`sim/cosim`)

A Verilator model of snestang's real firmware-facing interface logic — the
`iosys_bl616` UART protocol engine (with OSD text and the SAVE_RDY-style
save channel) and the `sdram_snes` controller (`sdram_cl2_2ch.v`, bank 1's
BSRAM port included) — plus snestang_top's BSRAM/save bridge, for the
TangCore firmware co-simulation (see firmware `host/README.md`, "RTL
backend"). No game, no video, no audio: it exercises firmware↔core
interactions (combos and pad frames during play, battery-save
dumps/restores contending with game BSRAM accesses, reset, MODE,
core_config bits) without hardware.

## Layout

- `cosim_top.sv` — the small top: real `iosys_bl616` (as
  `iosys_bl616_cosim`, generated, see below) + snestang_top's save↔BSRAM
  bridge (the arbiter copied verbatim; only its SNES-bus edge detectors
  are replaced by the traffic generator) + real `sdram_snes` wired as
  `snestang_top` wires them, plus sim-only surroundings: behavioral SDRAM
  chip (`sdram_chip.sv`), SNES-like CPU/ARAM traffic with a game
  BSRAM-write hook (`poke_*`, `churn_en`), a ROM byte sink, MODE silencing,
  and a `tx_pending` output so the bridge never jumps over a reply owed by
  the model. Clocks and reset come from C++ (`fclk` = 3× `clk`, coincident
  rising edges; `clk` IS the SNES mclk — iosys and the bridge run on it;
  `clkref` toggles on `clk`, the 1/6-of-fclk square wave the controller's
  frame resync wants; `hclk` tied to `clk`: the render pipeline is
  unobserved, OSD text is snapshotted straight out of the DPB array).
- `sdram_chip.sv` — behavioral 16-bit SDRAM (4 banks × 8K rows × 512
  words): the exact command subset `sdram_snes` issues (ACT, single-word
  READ/WRITE with auto-precharge, DQM-masked writes, CL2 reads;
  refresh/mode-set/precharge ignored). BSRAM sits at word 0x78_0000 (bank
  1, `{5'b01_111, bsram_addr[19:0]}`), so the C++ bridge reads save bytes
  at linear address 0xF0_0000 + offset. Powers up all-`0xFF` (blank
  battery RAM), retains contents across reset (external chip).
- `gowin/` — behavioural stand-ins for Gowin primitives, shared by every
  testbench and cosim target in this core: currently only the DPB behind
  `gowin_dpb_menu` (OSD text buffer; zero-init, render side unmodelled).
  Identical to nestang's — snestang's wrapper has the same ports.
- `Makefile` — `make model` (docker Verilator) builds
  `build/obj/Vsnestang_cosim__ALL.a` + `build/runtime/` (Verilator
  headers) for the firmware to link with `-DSNESTANG_COSIM_DIR`; the
  Verilated prefix differs from the NES model's (`Vcosim_top`) so one
  firmware binary can link both cores; `make lint` elaborates under
  iverilog (docker); `make clean`. `build/` is git-ignored.

## Generated sources (build-time, never committed)

`build/gen/` holds mechanical copies of real sources, each verified by the
build (grep checks + printed diff):

- `iosys_bl616_cosim.v` — from `src/iosys/iosys_bl616.v`, with exactly
  three changes: module renamed, the `CORE_ID` parameter deleted and added
  as the `cosim_core_id` input (programming the model answers as the
  programmed core; every reply byte stays DUT-generated), the `tx_data <=
  CORE_ID[7:0]` use pointed at it. Unlike the NES template there is no
  kbd_data softener: snestang's `kbd_data` is an output reg the sim
  tolerates (and the RX `0x0c` path that writes it never runs — the
  firmware sends no scancodes to core 2).
- `sdram_snes_sim.v` — from `src/sdram_cl2_2ch.v`: two port-declaration
  softeners (the Gowin-tolerated `inout reg` SDRAM_DQ, and `bsram_dout`
  declared `output reg` while driven by a continuous `assign`). No
  functional change.
- `uart_fixed_sim.v` — from `src/iosys/uart_fixed.v`: the dummy
  `ASSERTION_ERROR` instances (which iverilog discards with the false
  generate branch but Verilator elaborates) replaced by empty begins. No
  functional change.
- The verilate line waives five style warnings (`-Wno-PINMISSING` etc.)
  that the core's own RTL carries; the log is then grepped for any waived
  warning naming `cosim_top`, `sdram_chip` or `gowin_dpb` (a missing pin in
  our wiring once hid an unconnected `SDRAM_DQM`, which wrote both byte
  lanes on every write — the waivers must never cover our files).

## Tests

- `../saveram/run.sh` (iverilog, docker): the SNES save-channel unit
  testbench against iosys + a modelled bridge.
- The firmware `n-*.script` suite (`bash host/run-tests.sh --snes-rtl`
  over in the firmware worktree): menu combo and reset combo during a dump
  with the game writing BSRAM continuously (the bridge's SNES-first
  arbitration is real — save bytes slip between game accesses), save round
  trip through the SDRAM BSRAM window, core_config bits, MODE — all
  through the real serial link at the real baud.

## Porting notes (from the NES template)

What changed and why (everything else is the template, kept as-is):

1. iosys instance: `SAVE_RDY(1)` instead of `SAVE_SYNC(0)`, `SAVE_AW(17)`
   (128 KB BSRAM window), no kbd softeners.
2. The save channel is toggle-based (`sv_req/sv_ack`, `sv_rreq/sv_rack`)
   and lives behind snestang_top's bridge — the arbiter logic is copied
   into `cosim_top.sv` (it is top-level logic, not part of the controller).
   `tx_pending` therefore also includes `sv_req != sv_ack`: with
   SAVE_RDY=1 a restore byte can park in `RECV_SAVE_WAIT` until the SDRAM
   acks, and jumping that idle gap would stall the save engine forever.
3. Save base 0xF00000 (bank 1) instead of 0x3C0000; the traffic shape is
   BSRAM (the save window) + ROM/WRAM/ARAM reads instead of NES's WRAM
   window; `poke_off` widened to 16 bits (32 KB games).
4. The SDRAM chip model grew to 4 banks × 13 row bits (the controller
   interleaves three channels across banks; the NES chip collapsed to
   one).
