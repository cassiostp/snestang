#!/bin/sh
# Scanline sims (iverilog). From this directory: ./run.sh [standard|hz120|both]
# (default: both variants)
#   tb_scanlines     the row generator and the darkening (src/scanlines.v)
#   tb_snes_scaler   snes2hdmi whole frames, with a stub for the HDMI part
#                    (tb_snes_scaler_hz120.v for the hz120 variant: 480p
#                    geometry, the frame buffer, BFI, and PPM frame dumps)
set -e
cd "$(dirname "$0")"
RTL=../../src
VARIANT=${1:-both}
iverilog -g2012 -o tb_scanlines.out tb_scanlines.v $RTL/scanlines.v
vvp tb_scanlines.out
std() {
    iverilog -g2012 -I$RTL/variant/standard -o tb_snes_scaler.out tb_snes_scaler.v hdmi_stub.v \
        $RTL/snes2hdmi.v $RTL/scanlines.v $RTL/video_fx.v $RTL/dual_clk_fifo.v
    vvp tb_snes_scaler.out
}
hz() {
    iverilog -g2012 -DHZ120 -o tb_snes_scaler_hz120.out tb_snes_scaler_hz120.v hdmi_stub.v \
        $RTL/snes2hdmi.v $RTL/scanlines.v $RTL/video_fx.v $RTL/dual_clk_fifo.v
    vvp tb_snes_scaler_hz120.out
}
case "$VARIANT" in
    standard) std ;;
    hz120) hz ;;
    both) std; hz ;;
    *) echo "usage: $0 [standard|hz120|both]"; exit 1 ;;
esac
