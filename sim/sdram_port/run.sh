#!/bin/sh
# SDRAM CPU/CPU2 port sims (iverilog). From this directory:  ./run.sh
#   scenario 0  S-CPU traffic only, CPU2 idle
#   scenario 1  S-CPU + CPU2 back-to-back random reads (saturation)
#   scenario 2  S-CPU + CPU2 SA-1-like sequential reads with gaps
# If build/sdram_base.v exists (the controller before CPU2 was added, e.g.
# `git show origin/qa/round3:src/sdram_cl2_2ch.v > build/sdram_base.v`),
# scenario 0 also runs on it and the two fclk-by-fclk traces of the SDRAM
# bus and the CPU lane's outputs must be identical.
set -e
RTL=../../src
mkdir -p build
# the same two port-declaration softeners as sim/cosim/Makefile
soften() {
    sed -e 's/inout  reg \[15:0\] SDRAM_DQ/inout [15:0] SDRAM_DQ/' \
        -e 's/output reg  \[7:0\] bsram_dout/output [7:0] bsram_dout/' "$1" > "$2"
    ! grep -q "inout  reg" "$2"
    ! grep -q "output reg  \[7:0\] bsram_dout" "$2"
}
soften $RTL/sdram_cl2_2ch.v build/sdram_snes_sim.v
iverilog -g2012 -o build/tb.out tb_sdram_port.v build/sdram_snes_sim.v ../cosim/sdram_chip.sv
fail=0
# both phases of the S-CPU's (even-length) cycles against the 2-mclk rotation
for p in 0 1; do
    for s in 0 1 2; do
        (cd build && vvp -n tb.out +SCEN=$s +PHASE=$p +CYCLES=${CYCLES:-20000} +TRACE) | grep -v '^VCD' > build/scen$s.p$p.log
        grep -v "^ *[0-9][0-9]* \(S-CPU\|CPU2\|BSRAM\|WRAM\)" build/scen$s.p$p.log | sed "s/^scenario/phase $p, scenario/"
        mv build/trace.txt build/trace$s.p$p.txt
        grep -q "RESULT scen=$s s_errs=0 w_errs=0 wram_bad=0 m2_errs=0 b_errs=0" build/scen$s.p$p.log || { head -20 build/scen$s.p$p.log; fail=1; }
    done
    # the S-CPU's latest data edge with CPU2 busy must not be later than without
    m0=$(sed -n 's/.* s_max=\([0-9]*\).*/\1/p' build/scen0.p$p.log)
    for s in 1 2; do
        m=$(sed -n 's/.* s_max=\([0-9]*\).*/\1/p' build/scen$s.p$p.log)
        [ "$m" -le "$m0" ] || { echo "FAIL: phase $p scenario $s S-CPU latest edge $m > $m0"; fail=1; }
    done
done
if [ -f build/sdram_base.v ]; then
    soften build/sdram_base.v build/sdram_base_sim.v
    iverilog -g2012 -DBASELINE -o build/tb_base.out tb_sdram_port.v build/sdram_base_sim.v ../cosim/sdram_chip.sv
    for p in 0 1; do
        (cd build && vvp -n tb_base.out +SCEN=0 +PHASE=$p +CYCLES=${CYCLES:-20000} +TRACE) > build/base.p$p.log
        if cmp -s build/trace.txt build/trace0.p$p.txt; then
            echo "identity (phase $p): CPU2-idle trace matches the baseline controller ($(wc -l < build/trace0.p$p.txt) fclk cycles)"
        else
            echo "FAIL: phase $p CPU2-idle trace differs from the baseline controller"; fail=1
        fi
    done
fi
[ $fail = 0 ] && echo "ALL PASS" || { echo "FAILED"; exit 1; }
