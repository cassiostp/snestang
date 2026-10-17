#!/bin/sh
# Battery-save channel sim (iverilog). From this directory:
#   ./run.sh          compile and run tb_saveram
set -e
RTL=../../src
iverilog -g2012 -DSIM -o tb_saveram.out \
    tb_saveram.v \
    $RTL/iosys/iosys_bl616.v $RTL/iosys/uart_fixed.v
vvp tb_saveram.out
