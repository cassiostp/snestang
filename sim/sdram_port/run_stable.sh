#!/bin/sh
# Stability proof for both multicycle windows (sdcmc task). Same scenarios
# as run.sh, compiled with -DSDCMC_STABLE to add the launch-age detectors.
#
# fclk->mclk (multicycle 3): passes iff every run reports viol=0 with
# minage>=3: at each mclk-domain sample, no fclk launch in the SDRAM->SNES
# cone changed in the previous 3 fclk.
#
# mclk->fclk (multicycle 2): at each real capture edge (request lane at the
# controller's cycle[0], ARAM at cycle[2]) every mclk-launched input must be
# older than 1 fclk. Passes iff every run reports rq_e0=0, rq_v1=0 (no
# request-lane age 0 or 1) with rq_v2>0 (age-2 samples seen: the detectors
# are alive and the phase is as theorized), ar_v1>0 (the ARAM lane is
# exercised; its min age is 1 by construction, measured not gated), and
# lock_corr=0 (every clkref resync past startup found the rotation already
# at cycle[4]: the rotation is phase-locked to mclk).
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
        grep -h "STABLE\|RESULT\|RQSTABLE\|RQDET" build/stable$s.p$p.log | sed "s/^/phase $p, /"
        grep -q "RESULT scen=$s s_errs=0 w_errs=0 wram_bad=0 m2_errs=0 b_errs=0 a_errs=0" build/stable$s.p$p.log || { echo "FAIL: functional errors scen=$s phase=$p"; fail=1; }
        line=$(grep "STABLE scen=$s " build/stable$s.p$p.log)
        viol=$(echo "$line" | sed -n 's/.* viol=\([0-9-]*\).*/\1/p')
        minage=$(echo "$line" | sed -n 's/.* minage=\(-\?[0-9]*\).*/\1/p')
        [ "$viol" = "0" ] || { echo "FAIL: stability violations scen=$s phase=$p"; fail=1; }
        # age is fclk periods since the relevant launch last changed; the
        # multicycle-3 budget needs >= 3 (a change exactly on the sampling
        # edge has age 0 and is benign). Negative means FCLK_U is wrong.
        [ "${minage:-0}" -ge 3 ] || { echo "FAIL: minage=$minage < 3 scen=$s phase=$p"; fail=1; }
        rq=$(grep "RQSTABLE scen=$s " build/stable$s.p$p.log)
        rq_e0=$(echo "$rq" | sed -n 's/.* rq_e0=\([0-9-]*\).*/\1/p')
        rq_v1=$(echo "$rq" | sed -n 's/.* rq_v1=\([0-9-]*\).*/\1/p')
        rq_v2=$(echo "$rq" | sed -n 's/.* rq_v2=\([0-9-]*\).*/\1/p')
        rq_min=$(echo "$rq" | sed -n 's/.* rq_min=\([0-9-]*\).*/\1/p')
        ar_v1=$(echo "$rq" | sed -n 's/.* ar_v1=\([0-9-]*\).*/\1/p')
        ar_min=$(echo "$rq" | sed -n 's/.* ar_min=\([0-9-]*\).*/\1/p')
        lock_corr=$(echo "$rq" | sed -n 's/.* lock_corr=\([0-9-]*\).*/\1/p')
        areads=$(grep "RESULT scen=$s " build/stable$s.p$p.log | sed -n 's/.* a_reads=\([0-9-]*\).*/\1/p')
        # request lane: stable >= 2 fclk before the cycle[0] latch (setup-2)
        [ "$rq_e0" = "0" ] || { echo "FAIL: request-lane age-0 scen=$s phase=$p"; fail=1; }
        [ "$rq_v1" = "0" ] || { echo "FAIL: request-lane age-1 scen=$s phase=$p"; fail=1; }
        [ "${rq_v2:-0}" -gt 0 ] || { echo "FAIL: no age-2 request samples scen=$s phase=$p"; fail=1; }
        [ "${rq_min:-0}" -ge 2 ] || { echo "FAIL: rq_min=$rq_min < 2 scen=$s phase=$p"; fail=1; }
        # ARAM lane is exercised (its min age is 1 by construction: measured
        # in ar_min, not gated; the SDC still budgets a full mclk there)
        [ "${ar_v1:-0}" -gt 0 ] || { echo "FAIL: no age-1 ARAM samples scen=$s phase=$p"; fail=1; }
        [ "${areads:-0}" -ge 100 ] || { echo "FAIL: ARAM master idle scen=$s phase=$p"; fail=1; }
        echo "phase $p, scen $s: ARAM min age $ar_min (measured, not gated)"
        # rotation phase-locked to mclk: no resync moved it past startup
        [ "$lock_corr" = "0" ] || { echo "FAIL: lock_corr=$lock_corr scen=$s phase=$p"; fail=1; }
    done
done
[ $fail = 0 ] && echo "ALL STABLE" || { echo "FAILED"; exit 1; }
