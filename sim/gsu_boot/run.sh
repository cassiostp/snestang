#!/bin/sh
# Full-system GSU boot sim (Verilator). From the repo:
#   simrun --entrypoint sh --name ${SIM_PREFIX:-sim$$}_gsuboot \
#     --user $(id -u):$(id -g) -v <repo>:/w -w /w/sim/gsu_boot \
#     verilator/verilator:latest run.sh
# (simrun is an optional local helper; plain `docker run --rm` works too.)
# Needs network once (clones PeterLemon/SNES for the freely distributable
# GSU test ROM) and python3 on the host for check.py; set PETERLEMON_DIR
# to an existing clone to run offline. See README.md.
set -e
cd "$(dirname "$0")"
R=../..
B=build
PL=${PETERLEMON_DIR:-$B/peterlemon}
DEMO=${GSU_ROM:-$PL/CHIP/GSU/2BPP/FillPoly/256x192/GSU2BPP256x192FillPoly.sfc}
mkdir -p $B/run/roms $B/obj
if [ ! -f "$DEMO" ]; then
    test -z "${GSU_ROM:-}" || { echo "GSU_ROM not found: $GSU_ROM" >&2; exit 1; }
    git clone --depth 1 https://github.com/PeterLemon/SNES.git "$PL"
fi
python3 - "$DEMO" $B/run/roms/gsu.hex <<'EOF'
import sys
rom = open(sys.argv[1], "rb").read()
assert len(rom) == 32768
img = rom[0x7FC0:0x8000] + bytes(448) + rom
with open(sys.argv[2], "w") as f:
    for i in range(0, len(img), 16):
        f.write(" ".join("%02x" % b for b in img[i:i + 16]) + "\n")
EOF
cp -f loader_gsu.v $B/obj/test_loader.v
# sim config: the tree's verilator config + GSU on (CX4/SA1 stay off: VHDL)
sed 's|// `define CHIP_GSU|`define CHIP_GSU|' $R/src/verilator/config.v > $B/obj/config_gsu.v
grep -q '^`define CHIP_GSU' $B/obj/config_gsu.v
W=$(cd $R && pwd)
verilator --top-module snestang_top --cc --exe \
  -CFLAGS "-O2" \
  -I$W/src -I$W/src/spc700 -I$W/src/65C816 \
  --Mdir $B/obj/obj --prefix Vsnestang_gsu \
  -o Vsnestang_gsu \
  $B/obj/config_gsu.v \
  $B/obj/test_loader.v \
  $W/src/verilator/sdram_sim.v \
  $W/src/dsp.v $W/src/snestang_top.v $W/src/smp.v \
  $W/src/spc700/_spc700_package.v $W/src/spc700/addrgen.v \
  $W/src/spc700/addsub.v $W/src/spc700/alu.v $W/src/spc700/bcdadj.v \
  $W/src/spc700/mcode.v $W/src/spc700/muldiv.v $W/src/spc700/spc700.v \
  $W/src/cpu.v $W/src/ppu.v $W/src/CEGen.v $W/src/main.v \
  $W/src/ppucgram.v $W/src/chip/DSP/srtc_time_pack.v \
  $W/src/ppuhoam.v $W/src/ppuoam.v \
  $W/src/65C816/common.sv $W/src/65C816/ALU.v $W/src/65C816/AddSubBCD.v \
  $W/src/65C816/AddrGen.v $W/src/65C816/BCDAdder.v \
  $W/src/65C816/adder4.v $W/src/65C816/bit_adder.v $W/src/65C816/mcode.sv \
  $W/src/65C816/P65C816.v \
  $W/src/chip/DSP/DSP_LHRomMap.v $W/src/chip/DSP/OBC1.v \
  $W/src/chip/DSP/SRTC.v $W/src/chip/DSP/DSPn.v \
  $W/src/chip/GSU/GSU_PKG.v $W/src/chip/GSU/GSU.v $W/src/chip/GSU/GSUMap.v \
  $W/src/sa1_rom_cache.v $W/src/bwram_256k.v \
  $W/src/smc_parser.v $W/src/SNES.v $W/src/vram.v $W/src/swram.v \
  tb_gsu_boot.cpp
make -C $B/obj/obj -f Vsnestang_gsu.mk Vsnestang_gsu -j"$(nproc)"
cp -f $W/src/chip/DSP/*.hex $B/run/ 2>/dev/null || true
test -s $B/run/random_4m_words.hex || python3 -c \
  "open('$B/run/random_4m_words.hex','w').write('0000\n' * (4 * 1024 * 1024))"
(cd $B/run && ../obj/obj/Vsnestang_gsu -m 20000000 > gsu_boot.stdout 2>&1) || { cat $B/run/gsu_boot.stdout; exit 1; }
grep -E 'done:|tb_gsu_boot' $B/run/gsu_boot.stdout
python3 check.py "$DEMO" $B/run/bsram.bin
echo "gsu_boot: PASS"
