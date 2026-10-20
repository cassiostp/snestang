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

controls = """
`ifdef SNES_SAVESTATE
reg [2:0] tb_ss_op /*verilator public*/ = 0;
reg tb_ss_op_stb /*verilator public*/ = 0;
reg [19:0] tb_ss_raddr /*verilator public*/ = 0;
reg [19:0] tb_ss_waddr /*verilator public*/ = 0;
reg [7:0] tb_ss_wdin /*verilator public*/ = 0;
reg tb_ss_rd /*verilator public*/ = 0;
reg tb_ss_taken /*verilator public*/ = 0;
reg tb_ss_wr /*verilator public*/ = 0;
reg tb_game_reset /*verilator public*/ = 0;
assign ss_op = tb_ss_op;
assign ss_op_stb = tb_ss_op_stb;
assign ss_img_raddr = tb_ss_raddr;
assign ss_img_waddr = tb_ss_waddr;
assign ss_img_wdin = tb_ss_wdin;
assign ss_img_rd_stb = tb_ss_rd;
assign ss_img_taken = tb_ss_taken;
assign ss_img_abort = 1'b0;
assign ss_img_wr_stb = tb_ss_wr;
`endif
"""
text = text.replace("wire ss_img_rd_stb, ss_img_taken, ss_img_abort, ss_img_rdy, ss_img_wr_stb;", "wire ss_img_rd_stb, ss_img_taken, ss_img_abort, ss_img_wr_stb; wire ss_img_rdy /*verilator public*/;")
text = text.replace("wire [7:0] ss_img_q, ss_img_wdin;", "wire [7:0] ss_img_wdin; wire [7:0] ss_img_q /*verilator public*/;")
text = text.replace("`else       // VERILATOR", "`else       // VERILATOR\n" + controls)
text = text.replace("resetn & ~loading & ~ss_reset", "resetn & ~loading & ~ss_reset & ~tb_game_reset")

old = "test_loader test_loader (\n    .clk(mclk), .resetn(resetn),"
new = "test_loader test_loader (\n    .clk(mclk), .resetn(resetn & ~sdram_busy),"
if old not in text:
    sys.exit("test_loader reset not found")
text = text.replace(old, new, 1)
open(dst, "w").write(text)
print("patched top written")
