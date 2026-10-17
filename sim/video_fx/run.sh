#!/bin/sh
# video_fx sims (iverilog). From this directory:  ./run.sh
#   tb_iosys_video_config  iosys command 0x13
#   tb_video_fx     video_fx against the golden model (model.py)
#   tb_snes_regress snes2hdmi against the scaler before video_fx: identical with no filter on
#   tb_snes_fx      the filters inside snes2hdmi, checked against the model
#   tb_snes_linebuf the line buffer as the SNES fills it: every line the picture reads is there
#   tb_snes_hires   hi-res pair blending in snes2hdmi: alternating sub-pixels and pseudo-hi-res pairs
# prep.sh (python3, git) makes the vectors and the baselines; with a simulator image that has
# neither, run prep.sh on the host first and `python3 -I model.py check snes_fx.log` on the host.
set -e
cd "$(dirname "$0")"
RTL=../../src
HDMI=../scanlines/hdmi_stub.v
if command -v python3 >/dev/null 2>&1 && command -v git >/dev/null 2>&1; then
    sh prep.sh
fi
test -f vec_case.hex -a -f build/snes2hdmi_base.v -a -f build/scanlines_base.v

iverilog -g2012 -DSIM -o tb_iosys_video_config.out tb_iosys_video_config.v $RTL/iosys/iosys_bl616.v $RTL/iosys/uart_fixed.v
vvp tb_iosys_video_config.out

iverilog -g2012 -o tb_video_fx.out tb_video_fx.v $RTL/video_fx.v $RTL/scanlines.v
vvp tb_video_fx.out

iverilog -g2012 -o tb_snes_regress.out tb_snes_regress.v $HDMI $RTL/snes2hdmi.v $RTL/scanlines.v \
    $RTL/video_fx.v $RTL/dual_clk_fifo.v build/snes2hdmi_base.v build/scanlines_base.v
vvp tb_snes_regress.out

iverilog -g2012 -o tb_snes_fx.out tb_snes_fx.v $HDMI $RTL/snes2hdmi.v $RTL/scanlines.v $RTL/video_fx.v \
    $RTL/dual_clk_fifo.v
vvp tb_snes_fx.out

# mclk half-periods: 138K 21.5053763 MHz -> 23.2498 ns; 60K 21.484375 -> 23.2727
echo "tb_snes_linebuf at console138k mclk"
iverilog -g2012 -DMCLK_HALF_NS=23.2498 -o tb_snes_linebuf.out tb_snes_linebuf.v $HDMI $RTL/snes2hdmi.v $RTL/scanlines.v \
    $RTL/video_fx.v $RTL/dual_clk_fifo.v
vvp tb_snes_linebuf.out
echo "tb_snes_linebuf at console60k mclk"
iverilog -g2012 -DMCLK_HALF_NS=23.2727 -o tb_snes_linebuf.out tb_snes_linebuf.v $HDMI $RTL/snes2hdmi.v $RTL/scanlines.v \
    $RTL/video_fx.v $RTL/dual_clk_fifo.v
vvp tb_snes_linebuf.out

iverilog -g2012 -o tb_snes_hires.out tb_snes_hires.v $HDMI $RTL/snes2hdmi.v $RTL/scanlines.v \
    $RTL/video_fx.v $RTL/dual_clk_fifo.v
vvp tb_snes_hires.out
if command -v python3 >/dev/null 2>&1; then
    python3 -I model.py check snes_fx.log
else
    echo "NOTE: python3 not found, run: python3 -I model.py check snes_fx.log"
fi
