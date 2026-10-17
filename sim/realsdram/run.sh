#!/bin/sh
# Full-system SNES sim on the real sdram_snes controller (Verilator).
# From this directory, inside verilator/verilator (see README):
#   ./run.sh build
#   ./run.sh run <game> <rom> <frames> <outdir> [script]
# build/ is gitignored. ROM-derived output stays in <outdir>, never in git.
# Env: JOBS (default 4), SMOKE_SNES_MAXSIZE (loader array, default 4194816).
set -e
here=$(cd "$(dirname "$0")" && pwd)
src=$(cd "$here/../.." && pwd)
cmd=${1:-build}
MAXS=${SMOKE_SNES_MAXSIZE:-4194816}
JOBS=${JOBS:-4}
B=$here/build

quiet_copy() {
    python3 - "$src" "$B/gen" <<'EOF'
import sys, os
srcroot, genroot = sys.argv[1], sys.argv[2]
files = ["cpu.v", "smp.v", "dsp.v", "ppuhoam.v",
         "spc700/spc700.v", "chip/DSP/DSPn.v"]
for rel in files:
    s = os.path.join(srcroot, "src", rel)
    d = os.path.join(genroot, rel)
    os.makedirs(os.path.dirname(d), exist_ok=True)
    t = open(s).read()
    out, i, n = [], 0, len(t)
    changed = 0
    while i < n:
        if t.startswith("$fdisplay", i) and (i == 0 or not (t[i-1].isalnum() or t[i-1] == '_')):
            j = i
            depth = 0
            instr = False
            while j < n:
                c = t[j]
                if instr:
                    if c == '"': instr = False
                elif c == '"': instr = True
                elif c == '(': depth += 1
                elif c == ')':
                    depth -= 1
                    if depth == 0:
                        break
                elif c == ';' and depth == 0:
                    break
                j += 1
            assert j < n and t[j] in ');', (rel, t[max(0,i-40):i+40])
            if t[j] == ')':
                assert t[j+1] == ';'
                j += 1
            out.append("begin end // SIM-QUIET was $fdisplay")
            i = j + 1
            changed += 1
        else:
            out.append(t[i]); i += 1
    open(d, "w").write("".join(out))
    print("%s: neutralized %d" % (rel, changed))
EOF
}

do_build() {
    mkdir -p "$B/obj" "$B/gen"
    python3 "$here/patch_top.py" "$src/src/snestang_top.v" "$B/gen/snestang_top_sim.v"
    sed 's|// `define CHIP_GSU|`define CHIP_GSU|' "$src/src/verilator/config.v" > "$B/gen/config_gsu.v"
    grep -q '^`define CHIP_GSU' "$B/gen/config_gsu.v"
    quiet_copy
    sed -e 's/inout  reg \[15:0\] SDRAM_DQ/inout [15:0] SDRAM_DQ/' \
        -e 's/output reg  \[7:0\] bsram_dout/output [7:0] bsram_dout/' \
        "$src/src/sdram_cl2_2ch.v" > "$B/gen/sdram_snes_sim.v"
    ! grep -q "inout  reg" "$B/gen/sdram_snes_sim.v"
    ! grep -q "output reg  \[7:0\] bsram_dout" "$B/gen/sdram_snes_sim.v"
    sed "s/@SIZE@/$MAXS/" "$here/test_loader.v" > "$B/obj/test_loader.v"
    grep -q "localparam SIZE = $MAXS;" "$B/obj/test_loader.v"
    R=$src
    nice -n 10 verilator --top-module snes_realsdram_top --cc --exe \
      -CFLAGS "-O2" \
      -Wno-PINMISSING -Wno-IMPLICIT -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC \
      -Wno-CASEINCOMPLETE -Wno-CASEOVERLAP -Wno-UNDRIVEN \
      -I"$R/src" -I"$R/src/spc700" -I"$R/src/65C816" \
      --Mdir "$B/obj/obj" --prefix Vsnestang_smoke \
      -o Vsnestang_smoke \
      "$B/gen/config_gsu.v" \
      "$B/obj/test_loader.v" \
      "$B/gen/sdram_snes_sim.v" \
      "$R/sim/cosim/sdram_chip.sv" \
      "$here/snes_realsdram_top.sv" \
      "$B/gen/dsp.v" "$B/gen/snestang_top_sim.v" "$B/gen/smp.v" \
      "$R/src/controller_adapter.sv" \
      "$R/src/spc700/_spc700_package.v" "$R/src/spc700/addrgen.v" \
      "$R/src/spc700/addsub.v" "$R/src/spc700/alu.v" "$R/src/spc700/bcdadj.v" \
      "$R/src/spc700/mcode.v" "$R/src/spc700/muldiv.v" "$B/gen/spc700/spc700.v" \
      "$B/gen/cpu.v" "$R/src/ppu.v" "$R/src/CEGen.v" "$R/src/main.v" \
      "$R/src/ppucgram.v" "$R/src/chip/DSP/srtc_time_pack.v" \
      "$B/gen/ppuhoam.v" "$R/src/ppuoam.v" \
      "$R/src/65C816/common.sv" "$R/src/65C816/ALU.v" "$R/src/65C816/AddSubBCD.v" \
      "$R/src/65C816/AddrGen.v" "$R/src/65C816/BCDAdder.v" \
      "$R/src/65C816/bit_adder.v" "$R/src/65C816/mcode.sv" \
      "$R/src/65C816/P65C816.v" \
      "$R/src/chip/DSP/DSP_LHRomMap.v" "$R/src/chip/DSP/OBC1.v" \
      "$R/src/chip/DSP/SRTC.v" "$B/gen/chip/DSP/DSPn.v" \
      "$R/src/chip/GSU/GSU_PKG.v" "$R/src/chip/GSU/GSU.v" "$R/src/chip/GSU/GSUMap.v" \
      "$R/src/sa1_rom_cache.v" "$R/src/bwram_256k.v" \
      "$R/src/smc_parser.v" "$R/src/SNES.v" "$R/src/vram.v" "$R/src/swram.v" \
      "$here/tb_realsdram.cpp"
    nice -n 10 make -C "$B/obj/obj" -f Vsnestang_smoke.mk Vsnestang_smoke -j"$JOBS"
    echo BUILD_OK
}

do_run() {
    GAME=$2; ROM=$3; FRAMES=$4; OUT=$5; SCRIPT=$6
    test -n "$GAME" && test -n "$ROM" && test -n "$FRAMES" && test -n "$OUT" || {
        echo "usage: run.sh run <game> <rom> <frames> <outdir> [script]"; exit 1; }
    test -x "$B/obj/obj/Vsnestang_smoke" || { echo "model not built"; exit 1; }
    case $OUT in /*) ;; *) OUT=$PWD/$OUT;; esac
    case $ROM in /*) ;; *) ROM=$PWD/$ROM;; esac
    mkdir -p "$OUT" "$B/run"
    rm -f "$OUT/$GAME".log "$OUT/$GAME".aud "$OUT/$GAME".stdout "$OUT/$GAME".stderr \
          "$OUT/$GAME"_f*.ppm "$OUT/$GAME"_bsram.bin "$OUT/$GAME"_aram.bin
    R=$B/run/$GAME
    rm -rf "$R"; mkdir -p "$R/roms"
    SZ=$(python3 "$here/make_rom.py" "$ROM" "$R/roms/game.hex" | grep '^SIZE=' | cut -d= -f2)
    echo "$SZ" > "$R/roms/size.txt"
    echo "game=$GAME size=$SZ frames=$FRAMES"
    cp -f "$src/src/chip/DSP/"*.hex "$R/" 2>/dev/null || true
    # Load of a 2 MB image is ~8M mclk before the first frame; the behavioural
    # smoke budget's +20M is tight once the controller's 200 us init is added.
    MCLK=$((FRAMES * 357380 + 40000000))
    if [ "${DUMP_ALL_FRAMES:-0}" = 1 ]; then
        DUMPS=$(python3 -c "print(','.join(str(f) for f in range(0, int($FRAMES)+1, 2)))")
    else
        DUMPS=$(python3 -c "print(','.join(str(f) for f in [60,300,600,900,1200] if f <= $FRAMES))")
    fi
    echo "mclk budget: $MCLK dumps: $DUMPS"
    T0=$(date +%s)
    set +e
    (cd "$R" && nice -n 10 "$B/obj/obj/Vsnestang_smoke" -m "$MCLK" -o "$OUT/$GAME" \
        ${SCRIPT:+-i "$SCRIPT"} -d "$DUMPS" >"$OUT/$GAME.stdout" 2>"$OUT/$GAME.stderr")
    RC=$?
    set -e
    T1=$(date +%s)
    echo "RUN game=$GAME frames=$FRAMES wall=$((T1 - T0))s rc=$RC"
    test "$RC" = 0
}

case $cmd in
    build) do_build ;;
    run) do_run "$@" ;;
    *) echo "usage: run.sh build | run.sh run <game> <rom> <frames> <outdir> [script]"; exit 1 ;;
esac
