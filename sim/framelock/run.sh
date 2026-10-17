#!/bin/sh
# SNES frame-sync halt-lock sim (iverilog). From this directory: ./run.sh
#   tb_snes_framelock  the snes2hdmi halt-lock with a 1364-clock line at
#                      both boards' mclk, in 262-line and interlaced
#                      263/262-line modes, plus a slow-crystal case
set -e
cd "$(dirname "$0")"
RTL=../../src
HDMI=../scanlines/hdmi_stub.v
SRCS="$HDMI $RTL/snes2hdmi.v $RTL/scanlines.v $RTL/video_fx.v $RTL/dual_clk_fifo.v"

run() {
    name=$1; shift
    echo "== $name"
    iverilog -g2012 "$@" -o tb_snes_framelock.out tb_snes_framelock.v $SRCS
    vvp tb_snes_framelock.out
}

# mclk half-periods: 138K 21.5053763 MHz -> 23.2498 ns; 60K 21.484375 -> 23.2727
run "console138k 262-line"    -DMCLK_HALF_NS=23.2498 -DLINES_EVEN=262 -DLINES_ODD=262 -DLOCKED=1
run "console60k 262-line"     -DMCLK_HALF_NS=23.2727 -DLINES_EVEN=262 -DLINES_ODD=262 -DLOCKED=1
run "console138k interlaced"  -DMCLK_HALF_NS=23.2498 -DLINES_EVEN=263 -DLINES_ODD=262 -DLOCKED=0
run "console60k interlaced"   -DMCLK_HALF_NS=23.2727 -DLINES_EVEN=263 -DLINES_ODD=262 -DLOCKED=0
run "slow crystal 262-line"   -DMCLK_HALF_NS=23.28   -DLINES_EVEN=262 -DLINES_ODD=262 -DLOCKED=0
