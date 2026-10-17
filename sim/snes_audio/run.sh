#!/bin/sh
# SNES audio transport sim (iverilog). From this directory: ./run.sh [standard|hz120|both]
# (default: both variants)
#   tb_snes_audio_fifo  the snes2hdmi 32 kHz FIFO across the frame-sync halt:
#                       no dropped or repeated samples over 14 HDMI frames
#                       (counted from frame 2 standard, frame 4 hz120: frames
#                       0-3 are the 2x lock acquire),
#                       at both boards' mclk (the halt differs; the sample
#                       count per frame does not). console60k free-runs slower
#                       than the hz120 rate, so the hz120 run is 138K only.
set -e
cd "$(dirname "$0")"
RTL=../../src
HDMI=../scanlines/hdmi_stub.v
SRCS="$HDMI $RTL/snes2hdmi.v $RTL/scanlines.v $RTL/video_fx.v $RTL/dual_clk_fifo.v"
VARIANT=${1:-both}

# mclk half-periods: 138K 21.5053763 MHz -> 23.2498 ns; 60K 21.484375 -> 23.2727
std() {
    echo "== standard console138k mclk"
    iverilog -g2012 -I$RTL/variant/standard -DMCLK_HALF_NS=23.2498 -o tb_snes_audio_fifo.out tb_snes_audio_fifo.v $SRCS
    vvp tb_snes_audio_fifo.out
    echo "== standard console60k mclk"
    iverilog -g2012 -I$RTL/variant/standard -DMCLK_HALF_NS=23.2727 -o tb_snes_audio_fifo.out tb_snes_audio_fifo.v $SRCS
    vvp tb_snes_audio_fifo.out
}

hz() {
    echo "== hz120 console138k mclk"
    iverilog -g2012 -DHZ120 -DMCLK_HALF_NS=23.2498 -o tb_snes_audio_fifo.out tb_snes_audio_fifo.v $SRCS
    vvp tb_snes_audio_fifo.out
    # console60k free-runs slower than this 855-line rate, so the FIFO would
    # underrun. The 120 Hz build is console138k.
}

case "$VARIANT" in
    standard) std ;;
    hz120) hz ;;
    both) std; hz ;;
    *) echo "usage: $0 [standard|hz120|both]"; exit 1 ;;
esac
