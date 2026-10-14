#!/bin/sh
# Stability proof for the fclk->mclk multicycle-3 window (sdcmc task).
# Same scenarios as run.sh, compiled with -DSDCMC_STABLE. Passes iff every
# run reports viol=0 with minwin>=3: at each mclk-domain sample, no fclk
# launch in the SDRAM->SNES cone changed in the previous 3 fclk.
# From this directory:  ./run_stable.sh
set -e
RTL=../../src
mkdir -p build
soften() {
    sed -e 's/inout  reg \[15:0\] SDRAM_DQ/inout [15:0] SDRAM_DQ/' \
        -e 's/output reg  \[7:0\] bsram_dout/output [7:0] bsram_dout/' "$1" > "$2"
    ! grep -q "inout  reg" "$2"
    ! grep -q "output reg  \[7:0\] bsram_dout" "$2"
}
soften $RTL/sdram_cl2_2ch.v build/sdram_snes_sim.v
iverilog -g2012 -DSDCMC_STABLE -o build/tb_stable.out tb_sdram_port.v build/sdram_snes_sim.v ../cosim/sdram_chip.sv
fail=0
for p in 0 1; do
    for s in 0 1 2; do
        (cd build && vvp -n tb_stable.out +SCEN=$s +PHASE=$p +CYCLES=${CYCLES:-20000}) > build/stable$s.p$p.log 2>&1 || { echo "RUN FAILED scen=$s phase=$p"; fail=1; continue; }
        grep -h "STABLE\|RESULT" build/stable$s.p$p.log | sed "s/^/phase $p, /"
        grep -q "RESULT scen=$s s_errs=0 w_errs=0 wram_bad=0 m2_errs=0 b_errs=0" build/stable$s.p$p.log || { echo "FAIL: functional errors scen=$s phase=$p"; fail=1; }
        line=$(grep "STABLE scen=$s " build/stable$s.p$p.log)
        viol=$(echo "$line" | sed -n 's/.* viol=\([0-9-]*\).*/\1/p')
        minage=$(echo "$line" | sed -n 's/.* minage=\(-\?[0-9]*\).*/\1/p')
        [ "$viol" = "0" ] || { echo "FAIL: stability violations scen=$s phase=$p"; fail=1; }
        # age is fclk periods since the relevant launch last changed; the
        # multicycle-3 budget needs >= 3 (a change exactly on the sampling
        # edge has age 0 and is benign). Negative means FCLK_U is wrong.
        [ "${minage:-0}" -ge 3 ] || { echo "FAIL: minage=$minage < 3 scen=$s phase=$p"; fail=1; }
    done
done
[ $fail = 0 ] && echo "ALL STABLE" || { echo "FAILED"; exit 1; }
