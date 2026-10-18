#!/usr/bin/env python3
"""Exercise the actual top-level bridge; no duplicate bridge implementation."""
import sys
from pathlib import Path
source=Path(sys.argv[1]).read_text()
name=sys.argv[2]
a=source.index('reg [19:0]  bsram_addr;')
b=source.index('wire        aram_rd',a)
detect=source[a:b]
a=source.index('// ---- Save-RAM <-> BSRAM bridge')
b=source.index('// ---- SA-1:',a)
bridge=source[a:b]
bridge=bridge.replace('wire        bs_req_ack;', '// wire        bs_req_ack;')
if 'assign BSRAM_Q =' not in bridge:
 bridge+='\nassign BSRAM_Q = sa1_mode ? bwram_q_a : (snes_bsram_shadow ? snes_bsram_hold : bsram_dout);\n'
print(f'''module {name}(input mclk, input gsu_mode, sa1_mode, gsu_ram_req,
 input [7:0] rom_type, input [19:0] BSRAM_ADDR, input [7:0] BSRAM_D,
 input BSRAM_CE_N, BSRAM_RD_N, BSRAM_WE_N,
 input [17:0] sv_addr, input [7:0] sv_din, input sv_req, sv_rreq,
 input bs_req_ack, input [7:0] bsram_dout, output [7:0] BSRAM_Q);
localparam SAVE_AW=18;
wire [7:0] bwram_q_a=8'hc3;
wire gsu_ram_wait;
reg [7:0] snes_bsram_hold=0;
reg snes_bsram_shadow=0;
{detect}
initial begin bsram_addr=0; bsram_rd_r=0; bsram_wr_r=0; end
always @(posedge mclk) begin bsram_rd_r<=bsram_rd; bsram_wr_r<=bsram_wr; end
{bridge}
endmodule''')
