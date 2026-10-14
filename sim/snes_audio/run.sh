#!/bin/sh
# SNES audio transport sim (iverilog). From this directory:  ./run.sh
#   tb_snes_audio_fifo  the snes2hdmi 32 kHz FIFO across the frame-sync halt:
#                       no dropped or repeated samples over 14 HDMI frames
set -e
cd "$(dirname "$0")"
RTL=../../src
HDMI=../scanlines/hdmi_stub.v
iverilog -g2012 -o tb_snes_audio_fifo.out tb_snes_audio_fifo.v $HDMI \
    $RTL/snes2hdmi.v $RTL/scanlines.v $RTL/video_fx.v $RTL/smooth.v $RTL/dual_clk_fifo.v
vvp tb_snes_audio_fifo.out
