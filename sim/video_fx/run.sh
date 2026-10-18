#!/bin/sh
# video_fx sims (iverilog). From this directory: ./run.sh [standard|hz120|both]
# (default: both variants)
# standard:
#   tb_iosys_video_config  iosys command 0x13
#   tb_video_fx     video_fx against the golden model (model.py)
#   tb_snes_regress snes2hdmi against the scaler before video_fx: identical with no filter on
#   tb_snes_fx      the filters inside snes2hdmi, checked against the model
#   tb_snes_linebuf the line buffer as the SNES fills it: every line the picture reads is there
#   tb_snes_hires   hi-res pair blending in snes2hdmi: alternating sub-pixels and pseudo-hi-res pairs
# hz120 (480p120, -DHZ120):
#   tb_snes_fx      the filters inside snes2hdmi, checked against the model
#   tb_snes_framebuf the frame buffer as the SNES fills it: each game frame is
#                   shown twice and pairs step by one (138K locks, 60K free-runs)
#   tb_snes_hires   hi-res pair blending, and uniform grey end to end
#   (tb_snes_regress and tb_snes_linebuf are the 720p geometry: skipped)
# prep.sh (python3, git) makes the vectors and the baselines; with a simulator image that has
# neither, run prep.sh on the host first and `python3 -I model.py check snes_fx.log` on the host.
set -e
cd "$(dirname "$0")"
RTL=../../src
HDMI=../scanlines/hdmi_stub.v
VARIANT=${1:-both}
VSTD="-I$RTL/variant/standard"

std() {
    if command -v python3 >/dev/null 2>&1 && command -v git >/dev/null 2>&1; then
        sh prep.sh
    fi
    test -f vec_case.hex -a -f build/snes2hdmi_base.v -a -f build/scanlines_base.v

    iverilog -g2012 -DSIM -o tb_iosys_video_config.out tb_iosys_video_config.v $RTL/iosys/iosys_bl616.v $RTL/iosys/uart_fixed.v
    vvp tb_iosys_video_config.out

    iverilog -g2012 -o tb_video_fx.out tb_video_fx.v $RTL/video_fx.v $RTL/scanlines.v
    vvp tb_video_fx.out

    iverilog -g2012 $VSTD -o tb_snes_regress.out tb_snes_regress.v $HDMI $RTL/snes2hdmi.v $RTL/scanlines.v \
        $RTL/video_fx.v $RTL/dual_clk_fifo.v build/snes2hdmi_base.v build/scanlines_base.v
    vvp tb_snes_regress.out

    iverilog -g2012 $VSTD -o tb_snes_fx.out tb_snes_fx.v $HDMI $RTL/snes2hdmi.v $RTL/scanlines.v $RTL/video_fx.v \
        $RTL/dual_clk_fifo.v
    vvp tb_snes_fx.out

    # mclk half-periods: 138K 21.5053763 MHz -> 23.2498 ns; 60K 21.484375 -> 23.2727
    echo "standard tb_snes_linebuf at console138k mclk"
    iverilog -g2012 $VSTD -DMCLK_HALF_NS=23.2498 -o tb_snes_linebuf.out tb_snes_linebuf.v $HDMI $RTL/snes2hdmi.v $RTL/scanlines.v \
        $RTL/video_fx.v $RTL/dual_clk_fifo.v
    vvp tb_snes_linebuf.out
    echo "standard tb_snes_linebuf at console60k mclk"
    iverilog -g2012 $VSTD -DMCLK_HALF_NS=23.2727 -o tb_snes_linebuf.out tb_snes_linebuf.v $HDMI $RTL/snes2hdmi.v $RTL/scanlines.v \
        $RTL/video_fx.v $RTL/dual_clk_fifo.v
    vvp tb_snes_linebuf.out

    iverilog -g2012 $VSTD -o tb_snes_hires.out tb_snes_hires.v $HDMI $RTL/snes2hdmi.v $RTL/scanlines.v \
        $RTL/video_fx.v $RTL/dual_clk_fifo.v
    vvp tb_snes_hires.out
    if command -v python3 >/dev/null 2>&1; then
        python3 -I model.py check snes_fx.log
    else
        echo "NOTE: python3 not found, run: python3 -I model.py check snes_fx.log"
    fi
}

hz() {
    # The clock-for-clock regress against the 720p scaler does not apply at 480p.
    # Geometry, BFI and the filters are checked by tb_snes_scaler_hz120, tb_snes_fx and
    # tb_snes_framebuf instead.
    echo "skip tb_snes_regress (720p historical golden)"

    iverilog -g2012 -DHZ120 -o tb_snes_fx.out tb_snes_fx.v $HDMI $RTL/snes2hdmi.v $RTL/scanlines.v $RTL/video_fx.v \
        $RTL/dual_clk_fifo.v
    vvp tb_snes_fx.out

    # mclk half-periods: 138K 21.5053763 MHz -> 23.2498 ns; 60K 21.484375 -> 23.2727
    echo "hz120 tb_snes_framebuf at console138k mclk"
    iverilog -g2012 -DHZ120 -DMCLK_HALF_NS=23.2498 -DLOCKED=1 -o tb_snes_framebuf.out tb_snes_framebuf.v $HDMI \
        $RTL/snes2hdmi.v $RTL/scanlines.v $RTL/video_fx.v $RTL/dual_clk_fifo.v
    vvp tb_snes_framebuf.out
    echo "hz120 tb_snes_framebuf at console60k mclk (cannot lock this rate)"
    iverilog -g2012 -DHZ120 -DMCLK_HALF_NS=23.2727 -DLOCKED=0 -o tb_snes_framebuf.out tb_snes_framebuf.v $HDMI \
        $RTL/snes2hdmi.v $RTL/scanlines.v $RTL/video_fx.v $RTL/dual_clk_fifo.v
    vvp tb_snes_framebuf.out

    iverilog -g2012 -DHZ120 -o tb_snes_hires.out tb_snes_hires.v $HDMI $RTL/snes2hdmi.v $RTL/scanlines.v \
        $RTL/video_fx.v $RTL/dual_clk_fifo.v
    vvp tb_snes_hires.out
    if command -v python3 >/dev/null 2>&1; then
        python3 -I model.py check snes_fx.log
    else
        echo "NOTE: python3 not found, run: python3 -I model.py check snes_fx.log"
    fi
}

case "$VARIANT" in
    standard) std ;;
    hz120) hz ;;
    both) std; hz ;;
    *) echo "usage: $0 [standard|hz120|both]"; exit 1 ;;
esac
