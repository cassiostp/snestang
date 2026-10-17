#!/bin/sh
# Full-system CX4 boot sim (GHDL synthesis + Verilator). From the repo:
#   sh run.sh build                          (needs docker: GHDL + Verilator)
#   sh run.sh run <game.sfc> <frames> [outdir]
# build/ is git-ignored. ROM-derived outputs stay in <outdir>, never in git.
# Env: GHDL_IMG (any GHDL 5 LLVM image with the synth command),
#   JOBS (default 4), MAXSIZE (loader array bound, default 4194816: one
#   build serves every ROM up to 4 MB; per-game SIZE must fit it).
set -e
INVOCEDIR=$PWD
cd "$(dirname "$0")"
R=../..
B=build
GHDL_IMG=${GHDL_IMG:-cx4_ghdl:1}
JOBS=${JOBS:-4}
MAXSIZE=${MAXSIZE:-4194816}
cmd=${1:-build}
DOCK="docker run --rm --user $(id -u):$(id -g)"

do_build() {
    rm -rf $B/obj $B/gen $B/run
    mkdir -p $B/obj $B/gen $B/run/roms
    # 1. CX4 VHDL -> Verilog, then the mechanical fixups (see README).
    $DOCK --name cx4boot_synth -v "$R/src/chip/CX4:/chip:ro" -v "$PWD/$B:/b" -w /b \
        "$GHDL_IMG" \
        sh -c 'ghdl synth --std=08 -fsynopsys -frelaxed --out=verilog /chip/cx4_drom_pkg.vhd /chip/spram.vhd /chip/dpram_difclk.vhd /chip/cx4cache.vhd /chip/CEGen.vhd /chip/CX4.vhd /chip/CX4Map.vhd -e CX4Map > /b/cx4map_synth.v 2>/b/synth_err.log'
    python3 synth_fixup.py $B/cx4map_synth.v $B/cx4map_sim.v
    # 2. Sim config: the tree's verilator config + CHIP_CX4 (console138k has it).
    sed -e 's|`define CHIP_DSPn|`define CHIP_DSPn\n`define CHIP_CX4|' "$R/src/verilator/config.v" > "$B/gen/config_cx4.v"
    grep -q '^`define CHIP_CX4' "$B/gen/config_cx4.v"
    sed "s/@SIZE@/$MAXSIZE/" test_loader.v > "$B/obj/test_loader.v"
    # 3. Verilate (same source list as the smoke SNES model, plus the CX4).
    W=$(cd "$R" && pwd)
    $DOCK --entrypoint sh --name cx4boot_verilate \
        -v "$W:/w:ro" -v "$PWD/$B:/b" -v "$PWD:/h:ro" -w /b \
        verilator/verilator:latest -c "verilator --top-module snestang_top --cc --exe --Mdir /b/obj/obj --prefix Vsnestang_cx4boot -o Vsnestang_cx4boot -CFLAGS \"-O2\" -Wno-PINMISSING -Wno-IMPLICIT -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-CASEINCOMPLETE -Wno-UNDRIVEN -Wno-UNSIGNED -Wno-MULTIDRIVEN -I/w/src -I/w/src/spc700 -I/w/src/65C816 /b/gen/config_cx4.v /b/obj/test_loader.v /w/src/verilator/sdram_sim.v /w/src/dsp.v /w/src/snestang_top.v /w/src/smp.v /w/src/controller_adapter.sv /w/src/spc700/_spc700_package.v /w/src/spc700/addrgen.v /w/src/spc700/addsub.v /w/src/spc700/alu.v /w/src/spc700/bcdadj.v /w/src/spc700/mcode.v /w/src/spc700/muldiv.v /w/src/spc700/spc700.v /w/src/cpu.v /w/src/ppu.v /w/src/CEGen.v /w/src/main.v /b/cx4map_sim.v /w/src/ppucgram.v /w/src/chip/DSP/srtc_time_pack.v /w/src/ppuhoam.v /w/src/ppuoam.v /w/src/65C816/common.sv /w/src/65C816/ALU.v /w/src/65C816/AddSubBCD.v /w/src/65C816/AddrGen.v /w/src/65C816/BCDAdder.v /w/src/65C816/bit_adder.v /w/src/65C816/mcode.sv /w/src/65C816/P65C816.v /w/src/chip/DSP/DSP_LHRomMap.v /w/src/chip/DSP/OBC1.v /w/src/chip/DSP/SRTC.v /w/src/chip/DSP/DSPn.v /w/src/sa1_rom_cache.v /w/src/bwram_256k.v /w/src/smc_parser.v /w/src/SNES.v /w/src/vram.v /w/src/swram.v /h/tb_cx4_boot.cpp"
    # The CX4 hierarchy number below is Verilator's generate numbering;
    # abort here (not in C++) if a tool change renames it.
    grep -q "__PVT__genblk3__DOT__CX4Map__DOT__cx4__DOT__busy" $B/obj/obj/Vsnestang_cx4boot_main*.h
    $DOCK --entrypoint make --name cx4boot_make \
        -v "$PWD/$B:/b" -v "$PWD:/h:ro" -w /b/obj/obj \
        verilator/verilator:latest -C /b/obj/obj -f Vsnestang_cx4boot.mk Vsnestang_cx4boot -j"$JOBS"
    echo BUILD_OK
}

do_run() {  # do_run <game.sfc> <frames> [outdir]
    ROM=$1; FRAMES=$2; OUT=${3:-$B/run/game}
    case $ROM in /*) ;; *) ROM=$INVOCEDIR/$ROM;; esac
    mkdir -p "$OUT/roms"
    SZ=$(python3 - "$ROM" "$OUT/roms/game.hex" <<'EOF' | grep '^SIZE=' | cut -d= -f2
import struct, sys
src, dst = sys.argv[1], sys.argv[2]
raw = open(src, "rb").read()
if len(raw) % 1024 == 512:
    raw = raw[512:]
hdr = None
for off in (0x7FC0, 0xFFC0, 0x40FFC0):
    if off + 64 > len(raw):
        continue
    h = raw[off:off + 64]
    cs, cc = struct.unpack("<HH", h[0x1C:0x20])
    if ((cs + cc) & 0xFFFF) == 0xFFFF and hdr is None:
        hdr = h
if hdr is None:
    hdr = raw[0x7FC0:0x8000]
img = bytearray(512 + len(raw))
img[0:64] = hdr
img[512:] = raw
with open(dst, "w") as f:
    for b in img:
        f.write("%02x\n" % b)
print("SIZE=%d" % len(img))
EOF
)
    test "$SZ" -le "$MAXSIZE" || { echo "image $SZ exceeds build MAXSIZE $MAXSIZE"; exit 1; }
    echo "$SZ" > "$OUT/roms/size.txt"
    cp -f "$R/src/chip/DSP/"*.hex "$OUT/" 2>/dev/null || true
    test -s "$OUT/random_4m_words.hex" || python3 -c "open('$OUT/random_4m_words.hex','w').write('0000\n' * (4 * 1024 * 1024))"
    MCLK=$((FRAMES * 357380 + 40000000))
    (cd "$OUT" && "$HERE/$B/obj/obj/Vsnestang_cx4boot" -m "$MCLK" -t 10000000 -d 300,600,900,1200 | tee cx4boot.stdout)
}

HERE=$PWD
case $cmd in
    build) do_build;;
    run) shift; do_run "$@";;
    *) echo "usage: $0 {build|run <game.sfc> <frames> [outdir]}"; exit 1;;
esac
