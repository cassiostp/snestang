#!/bin/sh
# Headless SNES game-pattern sim (Verilator, via docker). From this directory:
#   ./run.sh      build the real core with a test loader, run the battery games
# Output goes to build/ (git-ignored). The only docker use is Verilator itself.
set -e
here=$(cd "$(dirname "$0")" && pwd)
src=$(cd "$here/../.." && pwd)
# Runner: simrun when present (persistent ccache + full-core env), else plain docker.
DOCKER_RUN=${DOCKER_RUN:-$(command -v simrun >/dev/null 2>&1 && echo simrun || echo "docker run --rm")};
# ccache: simrun mounts a persistent /ccache (CCACHE_DIR), so the Verilator
# build caches there; without it there is no cache to keep, so keep the old
# disable. (The generated makefiles already prefix compiles with $(OBJCACHE),
# which defaults to ccache: nothing else to set.)
case "$DOCKER_RUN" in *simrun*) CCACHE_OFF=;; *) CCACHE_OFF="-e CCACHE_DISABLE=1";; esac
mkdir -p "$here/build"
for rom in lorom:2 lorom:8 hirom:8; do
    python3 "$here/mkrom.py" "${rom%:*}" "${rom#*:}" "$here/build/${rom%:*}_${rom#*:}.hex" >/dev/null
done
# the sdram model preloads WRAM/ROM from this file when it starts; a short one is fine
echo 0000 > "$here/build/random_4m_words.hex"
cp "$src"/src/chip/DSP/*.hex "$here/build/" 2>/dev/null || true
# The real SDRAM controller, softened for Verilator exactly as sim/cosim/Makefile does
# (two port declarations Gowin accepts; no functional change).
sed -e 's/inout  reg \[15:0\] SDRAM_DQ/inout [15:0] SDRAM_DQ/' \
    -e 's/output reg  \[7:0\] bsram_dout/output [7:0] bsram_dout/' \
    "$src/src/sdram_cl2_2ch.v" > "$here/build/sdram_snes_sim.v"
! grep -q "inout  reg" "$here/build/sdram_snes_sim.v"
! grep -q "output reg  \[7:0\] bsram_dout" "$here/build/sdram_snes_sim.v"
D=/src/src
src_cosim=/src/sim/cosim
$DOCKER_RUN --user "$(id -u):$(id -g)" $CCACHE_OFF \
    -v "$src:/src:ro" -v "$here:/gs:ro" -v "$here/build:/out" -w /out \
    verilator/verilator:latest \
    --cc --exe --build -j "${JOBS:-$(nproc)}" --top-module gamesave_top --public-flat-rw \
    -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-CASEOVERLAP -Mdir obj -o gamesave \
    -I$D -I$D/spc700 -I$D/65C816 -CFLAGS -O2 \
    $D/verilator/config.v /gs/test_loader_sim.v /out/sdram_snes_sim.v $src_cosim/sdram_chip.sv /gs/gamesave_top.sv $D/dsp.v $D/snestang_top.v $D/smp.v \
    $D/spc700/_spc700_package.v $D/spc700/addrgen.v \
    $D/spc700/addsub.v $D/spc700/alu.v $D/spc700/bcdadj.v $D/spc700/mcode.v $D/spc700/muldiv.v $D/spc700/spc700.v \
    $D/cpu.v $D/ppu.v $D/CEGen.v $D/main.v $D/ppuhoam.v $D/ppuoam.v \
    $D/65C816/common.sv $D/65C816/ALU.v $D/65C816/AddSubBCD.v $D/65C816/AddrGen.v $D/65C816/BCDAdder.v \
    $D/65C816/adder4.v $D/65C816/bit_adder.v $D/65C816/mcode.sv $D/65C816/P65C816.v \
    $D/chip/DSP/DSP_LHRomMap.v $D/chip/DSP/OBC1.v $D/chip/DSP/SRTC.v $D/chip/DSP/DSPn.v \
    $D/smc_parser.v $D/SNES.v $D/vram.v $D/swram.v /gs/main.cpp > "$here/build/verilate.log" 2>&1 \
    || { tail -40 "$here/build/verilate.log"; exit 1; }
for rom in lorom:2 lorom:8 hirom:8; do
    n="${rom%:*}_${rom#*:}"
    size=$(( $(wc -l < "$here/build/$n.hex") ))
    echo "== $n ($size bytes streamed)"
    $DOCKER_RUN --user "$(id -u):$(id -g)" -v "$here/build:/out" -w /out --entrypoint /out/obj/gamesave \
        verilator/verilator:latest +rom=/out/$n.hex +size=$size +kind=$n
done
