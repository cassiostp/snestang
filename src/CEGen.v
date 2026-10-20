// File CEGen.vhd translated with vhd2vl 3.0 VHDL to Verilog RTL translator
// vhd2vl settings:
//  * Verilog Module Declaration Style: 2001

// vhd2vl is Free (libre) Software:
//   Copyright (C) 2001-2023 Vincenzo Liguori - Ocean Logic Pty Ltd
//     http://www.ocean-logic.com
//   Modifications Copyright (C) 2006 Mark Gonzales - PMC Sierra Inc
//   Modifications (C) 2010 Shankar Giri
//   Modifications Copyright (C) 2002-2023 Larry Doolittle
//     http://doolittle.icarus.com/~larry/vhd2vl/
//   Modifications (C) 2017 Rodrigo A. Melo
//
//   vhd2vl comes with ABSOLUTELY NO WARRANTY.  Always check the resulting
//   Verilog for correctness, ideally with a formal verification tool.
//
//   You are welcome to redistribute vhd2vl under certain conditions.
//   See the license (GPLv2) file included with the source for details.

// The result of translation follows.  Its copyright status should be
// considered unchanged from the original VHDL.

// no timescale needed

module CEGen(
  input wire CLK,
  input wire RST_N,
  input wire [31:0] IN_CLK,
  input wire [31:0] OUT_CLK,
  output reg CE

`ifdef SNES_SAVESTATE
    ,input ss_hold,
    input [12:0] ss_a,
    input [7:0] ss_d,
    input ss_we,
    output reg [7:0] ss_q
`endif
);

`ifdef SNES_SAVESTATE
  reg [31:0] CLK_SUM;
`endif
  always @(posedge CLK) begin : P1
`ifndef SNES_SAVESTATE
    reg [31:0] CLK_SUM;
`endif
`ifdef SNES_SAVESTATE
    if (ss_we) begin
      case (ss_a)
        13'h1ac0: CE <= ss_d[0:0];
        13'h1ac1: CLK_SUM[7:0] = ss_d;
        13'h1ac2: CLK_SUM[15:8] = ss_d;
        13'h1ac3: CLK_SUM[23:16] = ss_d;
        13'h1ac4: CLK_SUM[31:24] = ss_d;
        default: ;
      endcase
    end else if (!ss_hold || !RST_N) begin
`endif


    if(RST_N == 1'b0) begin
      CLK_SUM = 0;
      CE <= 1'b0;
    end else begin
      CE <= 1'b0;
      CLK_SUM = CLK_SUM + OUT_CLK;
      if(CLK_SUM >= IN_CLK) begin
        CLK_SUM = CLK_SUM - IN_CLK;
        CE <= 1'b1;
      end
    end

`ifdef SNES_SAVESTATE
    end
`endif
end



`ifdef SNES_SAVESTATE
// Register image; RAM and pipeline state are read only while frozen.
always @* begin
    ss_q = 8'b0;
    case (ss_a)
    13'h1ac0: ss_q = {7'b0, CE};
    13'h1ac1: ss_q = CLK_SUM[7:0];
    13'h1ac2: ss_q = CLK_SUM[15:8];
    13'h1ac3: ss_q = CLK_SUM[23:16];
    13'h1ac4: ss_q = CLK_SUM[31:24];
    default: ;
    endcase
end
`endif
endmodule
