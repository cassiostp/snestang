#!/bin/sh
# SNES audio transport sim (iverilog). From this directory:  ./run.sh
#   tb_snes_audio_fifo  the snes2hdmi 32 kHz FIFO across the frame-sync halt:
#                       no dropped or repeated samples over 14 HDMI frames,
#                       at both boards' mclk (the halt differs; the sample
#                       count per frame does not)
set -e
cd "$(dirname "$0")"
RTL=../../src
HDMI=../scanlines/hdmi_stub.v
SRCS="$HDMI $RTL/snes2hdmi.v $RTL/scanlines.v $RTL/video_fx.v $RTL/dual_clk_fifo.v"

# mclk half-periods: 138K 21.5053763 MHz -> 23.2498 ns; 60K 21.484375 -> 23.2727
echo "== console138k mclk"
iverilog -g2012 -DMCLK_HALF_NS=23.2498 -o tb_snes_audio_fifo.out tb_snes_audio_fifo.v $SRCS
vvp tb_snes_audio_fifo.out
echo "== console60k mclk"
iverilog -g2012 -DMCLK_HALF_NS=23.2727 -o tb_snes_audio_fifo.out tb_snes_audio_fifo.v $SRCS
vvp tb_snes_audio_fifo.out
