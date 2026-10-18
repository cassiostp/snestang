# video_fx sims (`sim/video_fx`)

Testbenches for `src/video_fx.v` (colour controls, CRT mask, LCD grid) and its
integration in `snes2hdmi`. iverilog; `./run.sh` runs everything.

| test | what it checks |
| --- | --- |
| `tb_iosys_video_config.v` | iosys command `0x13` through the real UART receiver: sets `video_config` big-endian, leaves `core_config` alone (and the other way round), ignores other commands, reset clears it |
| `tb_video_fx.v` | the module alone, against `model.py`: every brightness / contrast / saturation / gamma, every mask type and strength with the LCD grid off and at its four strengths, and 300 random settings with random pictures, borders, scanline darkening and grid flags |
| `tb_snes_regress.v` | `snes2hdmi` against the scaler before `video_fx` (built from git history by `prep.sh`, with the same integer-geometry change as `src/scanlines.v`: geometry follows Scale, darkening needs scanlines on): with a `video_config` that enables nothing (`0`, the firmware's all-off `0x00012000`, and `0x0003A000` with the grid bit the SNES ignores) the rgb stream into the hdmi module is identical clock for clock, two whole frames per scanline mode, with the menu overlay up or not; the line buffer is refilled with line-dependent pixels before every row, so a row that reads another source line is caught; the frame sync outputs (`pause_snes_for_frame_sync`, `hdmi_first_line`) must match too |
| `tb_snes_fx.v` + `model.py check` | the filters running inside `snes2hdmi`: the pixels going in and coming out of `video_fx` are logged with their output position and compared with the model, so the mask lands on the right columns and rows, the scanline darkening follows the colour stage, and the border and the overlay stay untouched |
| `tb_snes_linebuf.v` | the line buffer as the SNES fills it: a model of the PPU's pixel output and refresh drives the real frame sync, every write is tagged with its frame and line, and every read the picture depends on (the shown line) must find its own pixel, written and not yet overwritten; default and integer geometry, output rows, with the SNES slowed down by up to what the frame sync tolerates (`-Ptb_snes_linebuf.STALL=250`: one dot in 250 lost, the SNES frame is only 0.5 % shorter than the picture's). It reports, per setting, how long after the last read of a pixel it is overwritten, and how many lines the SNES is ahead of the picture (the buffer holds 32, so 31 is the limit) |
| `tb_snes_hires.v` | hi-res in `snes2hdmi`: hz120 blends each sub/main pair into the 256 frame buffer (alternating to grey, blue/red to half-and-half, pair boundaries, hblank dropped, grey end to end); standard stores 512 sub-pixels (both halves, `hires_lines` per line, mid-line toggle takes effect next line) and renders Full 1280 (2.5x) / Integer 1024 centred (2x) as alternating columns |
| `tb_snes_framebuf.v` | hz120 only: the frame buffer as the SNES fills it: a solid colour per game frame shows on both HDMI frames of a pair, pairs step by one, BFI off; a clock that cannot lock free-runs without a whole-frame halt |

`./run.sh [standard|hz120|both]` runs both build variants (default: both).
The hz120 variant compiles the scaler with `-DHZ120` (480p120, the frame
buffer, BFI); `tb_snes_regress` and `tb_snes_linebuf` are the 720p geometry
and are skipped there, and `tb_snes_framebuf` runs instead of the line buffer
bench.

The scaler has a single picture format, 256 x 224 into a 32-line buffer (no 512-wide or 239-line
mode), so the scanline modes and the overlay are all the modes there are.

`model.py` is the golden model, written from the spec (the `video_config` table in the header of
`video_fx.v`), not from the Verilog; `model.py selfcheck` also compares it with
real-number arithmetic and a few hand-computed values. `tools/video_fx_gamma.py`
generates the gamma tables inside `video_fx.v` (`--check` tells whether the file
is up to date); the model computes the tables itself.

`prep.sh` needs python3 and git (vectors from the model, the baseline scaler
from `$BASE`, the last commit without `video_fx`). The simulator image used on
arm64 (`tangcore-iv:1`) has neither: run `sh prep.sh` on the host, then
`docker run --rm --user $(id -u):$(id -g) -v $PWD/../..:/w -w /w/sim/video_fx tangcore-iv:1 sh run.sh`
and `python3 -I model.py check snes_fx.log` on the host.
`run.sh` runs `tb_snes_linebuf.v` with the SNES at full speed; the slowed-down runs are made by hand
(`iverilog -Ptb_snes_linebuf.STALL=250 ...`).
