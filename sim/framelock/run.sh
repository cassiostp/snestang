#!/bin/sh
# SNES frame-sync halt-lock sim (iverilog). From this directory: ./run.sh [standard|hz120|both]
# (default: both variants)
#   tb_snes_framelock  the snes2hdmi halt-lock with a 1364-clock line at
#                      both boards' mclk, in 262-line and interlaced
#                      263/262-line modes, plus a slow-crystal case.
#                      The hz120 variant locks at twice the game rate, so it
#                      runs 22 HDMI frames (11 game frames); console60k cannot
#                      lock the 855-line rate and free-runs.
set -e
cd "$(dirname "$0")"
RTL=../../src
HDMI=../scanlines/hdmi_stub.v
SRCS="$HDMI $RTL/snes2hdmi.v $RTL/scanlines.v $RTL/video_fx.v $RTL/dual_clk_fifo.v"
VARIANT=${1:-both}

run() {
    name=$1; shift
    echo "== $name"
    iverilog -g2012 "$@" -o tb_snes_framelock.out tb_snes_framelock.v $SRCS
    vvp tb_snes_framelock.out
}

std() {
    # mclk half-periods: 138K 21.5053763 MHz -> 23.2498 ns; 60K 21.484375 -> 23.2727
    run "standard console138k 262-line"   -I$RTL/variant/standard -DMCLK_HALF_NS=23.2498 -DLINES_EVEN=262 -DLINES_ODD=262 -DLOCKED=1
    run "standard console60k 262-line"    -I$RTL/variant/standard -DMCLK_HALF_NS=23.2727 -DLINES_EVEN=262 -DLINES_ODD=262 -DLOCKED=1
    run "standard console138k interlaced" -I$RTL/variant/standard -DMCLK_HALF_NS=23.2498 -DLINES_EVEN=263 -DLINES_ODD=262 -DLOCKED=0
    run "standard console60k interlaced"  -I$RTL/variant/standard -DMCLK_HALF_NS=23.2727 -DLINES_EVEN=263 -DLINES_ODD=262 -DLOCKED=0
    run "standard slow crystal 262-line"  -I$RTL/variant/standard -DMCLK_HALF_NS=23.28   -DLINES_EVEN=262 -DLINES_ODD=262 -DLOCKED=0
}

hz() {
    run "hz120 console138k 262-line"    -DHZ120 -DMCLK_HALF_NS=23.2498 -DLINES_EVEN=262 -DLINES_ODD=262 -DLOCKED=1
    # 60K free-runs slower than 60.1504 Hz, so this line length cannot lock
    run "hz120 console60k 262-line"     -DHZ120 -DMCLK_HALF_NS=23.2727 -DLINES_EVEN=262 -DLINES_ODD=262 -DLOCKED=0
    run "hz120 console138k interlaced"  -DHZ120 -DMCLK_HALF_NS=23.2498 -DLINES_EVEN=263 -DLINES_ODD=262 -DLOCKED=0
    run "hz120 console60k interlaced"   -DHZ120 -DMCLK_HALF_NS=23.2727 -DLINES_EVEN=263 -DLINES_ODD=262 -DLOCKED=0
    run "hz120 slow crystal 262-line"   -DHZ120 -DMCLK_HALF_NS=23.28   -DLINES_EVEN=262 -DLINES_ODD=262 -DLOCKED=0
}

case "$VARIANT" in
    standard) std ;;
    hz120) hz ;;
    both) std; hz ;;
    *) echo "usage: $0 [standard|hz120|both]"; exit 1 ;;
esac
