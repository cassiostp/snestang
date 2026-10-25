#!/usr/bin/env python3
"""Prepare an exhaustive-address comparison of actual old/new CPU P4 RTL."""
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parents[2]
old = subprocess.check_output(['git', 'show', '292d641:src/cpu.v'], cwd=root, text=True)
old = old[old.index('always @* begin : P4'):old.index('\nassign JPIO67')]
source = (root / 'src/cpu.v').read_text()
start = source.index('(* syn_keep = 1 *) reg [7:0] p65_io_q;')
new = source[start:source.index('\n`else\n', start)]
old = old.replace('P65_DI', 'q_ref').replace('begin : P4', 'begin : P4_ref')
new = new.replace('P65_DI', 'q_new')
tb = '''`timescale 1ns/1ps
module tb_io_mux;
reg IO_SEL;
reg [23:0] P65_A;
reg [7:0] DI,MDR;
reg NMI_FLAG,IRQ_FLAG,VBLANK,HBLANK,JOYRD_BUSY;
reg [15:0] RDDIV,RDMPY,JOY1_DATA,JOY2_DATA,JOY3_DATA,JOY4_DATA;
reg [1:0] JOY1_DI,JOY2_DI;
reg [7:0] DMAP[0:7],BBAD[0:7],A1B[0:7],DASB[0:7],NTLR[0:7],UNUSED[0:7];
reg [15:0] A1T[0:7],DAS[0:7],A2A[0:7];
reg [7:0] q_ref,q_new;
'''+old+'\n'+new+'''
integer seed,sel,address,j,cases=0;
initial begin
 for(seed=0;seed<4;seed=seed+1)begin
  DI=$random;MDR=$random;
  {NMI_FLAG,IRQ_FLAG,VBLANK,HBLANK,JOYRD_BUSY}=$random;
  RDDIV=$random;RDMPY=$random;
  JOY1_DATA=$random;JOY2_DATA=$random;JOY3_DATA=$random;JOY4_DATA=$random;
  JOY1_DI=$random;JOY2_DI=$random;
  for(j=0;j<8;j=j+1)begin
   DMAP[j]=$random;BBAD[j]=$random;A1B[j]=$random;DASB[j]=$random;
   NTLR[j]=$random;UNUSED[j]=$random;A1T[j]=$random;DAS[j]=$random;A2A[j]=$random;
  end
  for(sel=0;sel<2;sel=sel+1)begin
   IO_SEL=sel;
   for(address=0;address<65536;address=address+1)begin
    P65_A={8'(seed*64),16'(address)};#1;
    if(q_ref!==q_new)$fatal(1,"IO mux difference sel=%0d address=%h old=%h new=%h",IO_SEL,P65_A,q_ref,q_new);
    cases=cases+1;
   end
  end
 end
 $display("PASS: %0d full-address/data-set I/O mux comparisons",cases);
 $finish;
end
endmodule
'''
build = root / 'sim/savestate/build'
build.mkdir(exist_ok=True)
(build / 'tb_io_mux.v').write_text(tb)
mutant = tb.replace('if (IO_SEL) q_new = p65_io_q;', 'if (!IO_SEL) q_new = p65_io_q;')
assert mutant != tb
(build / 'tb_io_mux_mutant.v').write_text(mutant)
