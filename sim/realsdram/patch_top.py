#!/usr/bin/env python3
"""Sim-only patches of snestang_top.v for the real-SDRAM full-system model.

Joypad shim: same injection as tools/smoke/snes/build.sh, so a frame script
can drive P1 through controller_adapter.

Loader gate: the smoke loader starts streaming on resetn. The real
controller ignores requests until its 200 us init finishes, and a toggle
issued in that window is not a queued write. Hold the loader in reset
until sdram_busy falls. On hardware the firmware streams the ROM seconds
later, so this only matches the two.
"""
import sys

src, dst = sys.argv[1], sys.argv[2]
lines = open(src).read().splitlines(True)
inject = [
    "reg [11:0] tb_joy1 /*verilator public*/ = 12'b0;\n",
    "controller_adapter tb_joy1_adapter (.clk(mclk), .snes_buttons({4'b0, tb_joy1}),\n",
    "    .snes_joy_strb(snes_joy_strb), .snes_joy_clk(snes_joy1_clk), .snes_joy_di(snes_joy1_di[0]));\n",
    "assign snes_joy1_di[1] = 1'b1;\n",
    "assign snes_joy2_di = 2'b11;\n",
]
out, joy = [], False
for ln in lines:
    out.append(ln)
    if not joy and ln.startswith("`else") and "VERILATOR" in ln and "ifndef" not in ln:
        out.extend(inject)
        joy = True
if not joy:
    sys.exit("VERILATOR else not found")
text = "".join(out)
old = "test_loader test_loader (\n    .clk(mclk), .resetn(resetn),"
new = "test_loader test_loader (\n    .clk(mclk), .resetn(resetn & ~sdram_busy),"
if old not in text:
    sys.exit("test_loader reset not found")
text = text.replace(old, new, 1)
open(dst, "w").write(text)
print("patched top written")
