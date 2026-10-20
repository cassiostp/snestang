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
    # the Lottes table the modes-2/3 checks read: committed, verified fresh
    # here when python3 exists (else verify on the host:
    # python3 ../../tools/bfi_lottes.py --hex | cmp -s bfi_lottes.hex -)
    if command -v python3 >/dev/null 2>&1; then
        python3 ../../tools/bfi_lottes.py --hex | cmp -s bfi_lottes.hex - || { echo "bfi_lottes.hex is stale: regenerate with tools/bfi_lottes.py --hex"; exit 1; }
    else
        echo "note: no python3 here, skipping bfi_lottes.hex freshness check"
    fi
    iverilog -g2012 -DHZ120 -o tb_snes_scaler_hz120.out tb_snes_scaler_hz120.v hdmi_stub.v \
        $RTL/snes2hdmi.v $RTL/scanlines.v $RTL/video_fx.v $RTL/dual_clk_fifo.v
    vvp tb_snes_scaler_hz120.out
    # negative control: the same binary with one corrupted table entry
    # (code 0x70) must fail the exact pair check
    mkdir -p negative
    cp tb_snes_scaler_hz120.out negative/
    cp bfi_lottes.hex negative/
    sed -i '113s/^../ff/' negative/bfi_lottes.hex
    if (cd negative && vvp tb_snes_scaler_hz120.out > neg.log 2>&1); then
        echo "FAIL: negative control passed with a corrupted table"; exit 1;
    else
        grep -q "not a table pair" negative/neg.log || { echo "FAIL: negative control failed without the pair check"; cat negative/neg.log; exit 1; }
        echo "negative control: corrupted table fails as expected"
    fi
}
case "$VARIANT" in
    standard) std ;;
    hz120) hz ;;
    both) std; hz ;;
    *) echo "usage: $0 [standard|hz120|both]"; exit 1 ;;
esac
