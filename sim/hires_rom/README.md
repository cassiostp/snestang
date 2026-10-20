# hires_rom: homebrew hi-res test ROM (tangcore#23)

Small 65816 test (own code, assembled locally) showing a mode-5 screen and a
pseudo-hi-res screen with a known pattern: single-pixel blue/red columns
(stripe tile, plane0 `0xAA`) and text (`HIRES MODE5` font tiles). Palette:
CGRAM[0] blue, CGRAM[1] red.

- `hires_test.asm`: 65816 source (subset in `build.py`). LoROM 32KB.
  Mode 5 (`BGMODE 5`, `SETINI 0`, `TM=TS=1`) 120 frames, then pseudo
  (`BGMODE 1`, `SETINI $08`, `TM=1 TS=0` so sub = backdrop blue) 120 frames,
  loops via NMI frame counter at `$0000`.
- `build.py`: tiny 65816 assembler (Python3 only, no external assembler) plus
  tile/map/CGRAM data and the LoROM header/vectors. `run.sh` rebuilds
  `hires_test.sfc` from `hires_test.asm` and `cmp`s it byte-identical against
  the committed binary, so the binary can't drift from the source.
- `tb_hires_rom.v` (iverilog): the ROM's stripe (`0xAA`) and `H` glyph row
  (`0x81`) with PPU timing into the real `snes2hdmi` (standard 512-wide):
  both halves stored distinctly, `hires_lines` set. PASS (518 checks).
- `tb_hires_flag.sv` + `run_flag.sh` (Verilator, real `SPPU`): CPU-bus writes
  as the ROM does; `HIGH_RES` is 1 for mode 5, 1 for pseudo (`PSEUDOHIRES` &&
  `~BLEND`, `BLEND` tied 0), 0 for mode 1 normal, 1 for mode 6. PASS.
- `run.sh`: iverilog `tb_hires_rom`.

PPU output format (Verified, `src/ppu.v:906,2324-2333`, `src/snestang_top.v:285`):
`HIGH_RES = HIRES || PSEUDOHIRES` (`BLEND=0`), `COLOR_OUT = DOT_CLK ? SUB :
MAIN`, `X_OUT = {OUT_X, DOT_CLK}` — sub then main per dot, matching bsnes
`sfc/ppu/screen.cpp` `run()` (`hires = pseudo||mode5||mode6`, first pixel
`below`, second `above`) and fullsnes `SETINI` bit3 (sub shifted half dot left).

Hardware: copy `hires_test.sfc` to the card. Mode-5 phase: blue/red single-pixel
columns + red `HIRES MODE5` on blue. Pseudo phase: same pattern with sub =
blue (backdrop). On the fixed standard build columns are full-resolution
(512); on hz120/the old build pairs blend. Compare with bsnes rendering of the
same ROM.
