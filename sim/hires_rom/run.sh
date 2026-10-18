#!/bin/sh
# hires_rom iverilog sim. From this directory: ./run.sh
set -e
cd "$(dirname "$0")"
RTL=../../src
iverilog -g2012 -I$RTL/variant/standard -o tb_hires_rom.out tb_hires_rom.v $RTL/snes2hdmi.v $RTL/scanlines.v \
    $RTL/video_fx.v $RTL/dual_clk_fifo.v ../scanlines/hdmi_stub.v
vvp tb_hires_rom.out
