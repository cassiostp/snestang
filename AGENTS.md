Read the project-wide rules first: https://github.com/cassiostp/tangcore/blob/main/AGENTS.md

# snestang — SNES core

SNES for the Tang Console 138K/60K. Port of `nand2mario/snestang` (which ports `gyurco/SNES_FPGA` by srg320/gyurco); HDMI path uses `hdl-util/hdmi`.

## Layout

- Top: `src/snestang_top.v` (`module snestang_top`, needs `src/config.v` first), machine in `src/main.v`, PPU/S-CPU/DSP/SA-1/GSU/CX4 under `src/`.
- Video: scaler `src/snes2hdmi.v` (nano: `src/snes2hdmi_nano.v`) into `src/hdmi2/hdmi.sv` + helpers; `src/scanlines.v`, `src/video_fx.v`, `src/smooth.v`.
- Memory: `src/sdram_cl2_3ch.v` (primer25k/mega60k/console60k), `src/sdram_cl2_2ch.v` + FPGA BRAM `src/vram.v`/`vram_spb.v` (mega138k/console138k), `src/sdram_nano.v` (nano); SA-1 BW-RAM `src/bwram_256k.v`; `src/swram.v`, `src/gowin_dpb_*.v`.
- iosys: `src/iosys/iosys_bl616.v` is the build's copy (`uart_fixed.v`, `textdisp.v`, `gowin_dpb_menu.v`, `crc16.v`). `iosys_picorv32.v`/`picorv32.v` exist but are not in `build.tcl`.
- PLLs: `src/pll/` (138K `PLL`), `src/plla/` (25K/60K `PLLA`), `src/pllr/` (nano `rPLL`); `pll_12.v` feeds USB.

## Building

```tcl
gw_sh build.tcl <device> [<controller>]   # device includes console60k console138k (+nano20k primer25k mega60k mega138k); controller: snes ds2 (default ds2)
```

`console138k` uses `src/boards/console.cst` + `src/pll/*`; `console60k` ds2 uses the same `console.cst`, snes uses the SNES-controller cst. CI:

```sh
gh workflow run cores.yml -R cassiostp/tangcore --ref ci/core-builds -f core=snestang -f ref=<branch> -f board=console138k
```

Fails on any setup/hold violation; artifact holds the `.bin` and timing/utilisation reports.

## Clocks and constraints

- `console60k` (and primer/mega60k/nano): `src/snestang.sdc` — `sys_clk` 50 MHz, `fclk` 85.94 MHz, `mclk = fclk/4` ~21.48 MHz, `hclk5` 371.25 MHz, `hclk = hclk5/5`. This branch's scaler is 480p, so a 60K build of it does not match that pixel clock and cannot lock the rate.
- `console138k`/`mega138k`: `src/boards/console138k.sdc` — same `sys_clk`, `fclk` 64.5161 MHz and `mclk = fclk/3` ~21.505 MHz, `hclk5` 270 MHz (period 3.7037 ns), `hclk = hclk5/5` = 54 MHz. Gowin reads one SDC per project; `build.tcl` picks one or the other, never both. `src/boards/mega138k.sdc` exists but is not referenced.
- PLLs: `gowin_pll_snes` (`sys_clk -> mclk/fclk`), `gowin_pll_27` (`sys_clk -> 27 MHz`), `gowin_pll_hdmi` (`27 MHz -> hclk5/hclk`). The top comments the two rate pairs (`snestang_top.v`).

## Native-rate lock

This branch is the 120 Hz build: 480p (VIC 48) at 54 MHz, native line 855 (`NATIVE_FRAME_WIDTH` in `src/snes2hdmi.v`). 54 MHz/(855x525) = 120.3008 Hz, so the locked game runs at 60.1504 Hz (0.068 % faster than the 60 Hz build's 60.1093 Hz, 0.086 % faster than the SNES 60.0988 Hz). `std_timing = 1` selects the standard 858-pixel 120 Hz line; `video_std_timing` is tied `1'b0` in `src/snestang_top.v`.
The scaler sets `pause_snes_for_frame_sync` when the picture is in the frame buffer (OUT_Y 224) and clears it at HDMI row 64 of every second frame; the top gates `ENABLE` on it (`snestang_top.v`). Interlace and a clock that cannot lock free-run, documented in `sim/framelock/README.md`. `video_config[21:20]` is BFI (0 off, 1 black, 2 dim, 3 treated as black).

## Firmware link

- Core ID 2 (`CORE_ID(2)` in `src/snestang_top.v`; firmware maps 2 to `snestang.bin`).
- Save channel `SAVE_IF=1, SAVE_RDY=1`, `SAVE_AW=17` (18 with SA-1): BSRAM at SDRAM bank 1 (SA-1 diverts to `bwram_256k` second port), 512-byte `0x11/0x12/0x0A/0x0B` protocol with `sv_req/sv_ack` + `sv_rreq/sv_rack`.
- `core_config` bits used: `[17]` menu pause, `[16]` scanlines, `[19:18]` darkness, `[20]` thick, `[21]` out, `[22]` pads-muted; `video_config` (`0x13`) drives `video_fx.v`.
- `iosys_bl616.v` is one of six divergent copies (`cassiostp/tangcore#30`): a fix to one usually belongs in the others.

## Simulations (`sim/*/README.md` says how to run; iverilog in `tangcore-iv:1`, GHDL/Verilator where noted)

- `cosim`: Verilator model of `iosys_bl616`+SDRAM+save bridge for firmware co-sim.
- `cx4`: GHDL `tb_cx4.vhd` vs known results (regs, LoROM map, hand-assembled CX4 program).
- `dsp_rain`: Zelda rain (noise/music/sfx, `ENDX`, `TPITCH`, `FLG` mute, echo).
- `framelock`: 855-pixel 120 Hz line vs the 1364-clock SNES line; one halt per game frame when locked (two HDMI frames), interlace/slow-crystal/60K must free-run.
- `gsu_boot`: PeterLemon `GSU2BPP FillPoly` on full-chip Verilator; tables + picture match.
- `gsu_halt`: NOP sled with `ENABLE` low; PC/ROM/RAM frozen.
- `ppu_sprite`: left-edge 16x16 sprite slivers (regression `tangcore#19`).
- `ppu_timing`: 1364 clocks/line, 1360 short line, 263/262 interlace.
- `sa1_cache`: `sa1_rom_cache`+`bwram_256k` vs behavioural CPU2.
- `sa1_core`: GHDL SA-1 program, DMA/VBP, CXB bank.
- `saveram`: 2 Mbaud restore/dump/dirty/joypad interleave under back-pressure.
- `scanlines`: `sl_rows` geometry/darkening plus whole-frame scaler-vs-model.
- `scpu_timing`: 1x WRAM refresh/scanline + H-IRQ/HDMA positions.
- `sdram_port`: port-level `sdram_cl2_2ch.v` (S-CPU + CPU2 + ARAM + BSRAM); `run_stable.sh` proves SDC windows.
- `snes_audio`: 32 kHz FIFO+servo vs `tangcore#26` (16 NTSC frames, no drop/repeat after warmup).
- `srtc`: `srtc_time_pack` firmware-BCD to MiSTer nibble map; `smc_parser` `0x35/0x55`.
- `tmds`: 2-stage `tmds_channel` vs git-history `old` over 2.5M clocks.
- `video_fx`: `0x13`, `video_fx` vs `model.py`, git-history regress with filters off, FX/smoothing/linebuf/hires checks.

## Traps

- `build.tcl` names `src/boards/console60k_snescontroller.v/.cst`; on disk the file is `comsole60k_snescontroller.v` (typo) plus `console_snescontroller.cst`. The usage string omits `console138k`.
- The 60K fit omits GSU/SA-1/CX4 and `bwram_256k` (board wrapper defines `SDRAM_3CH` + DSP only); 138K has them with the 2-channel SDRAM + BRAM VRAM.
- `design.md` notes little timing leeway; the `mclk->fclk` multicycle and ARAM windows are load-bearing (`sim/sdram_port` guards them).
