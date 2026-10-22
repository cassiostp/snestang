
import spc700::*;

module MulDiv(
    input CLK,
    input RST_N,
    input EN,
    input SpcALUCtrl_r CTRL,
    input [7:0] A,
    input [7:0] X,
    input [7:0] Y,
    output [15:0] RES,
    output ZO,
    output VO,
    output HO,
    output SO

`ifdef SNES_SAVESTATE
    ,input ss_hold,
    input [12:0] ss_a,
    input [7:0] ss_d,
    input ss_we,
    output reg [7:0] ss_q
`endif
);

reg [15:0] tResult;
reg tV, tZ, tS;
reg [15:0] mulRes, mulTemp;
reg [15:0] mulA;
reg [7:0] mulY;
reg [15:0] divt;
reg [8:0] quotient;
reg [15:0] remainder;

always @(posedge CLK) begin
`ifdef SNES_SAVESTATE
    if (ss_we) begin
      case (ss_a)
        13'h1a80: mulRes[7:0] <= ss_d;
        13'h1a81: mulRes[15:8] <= ss_d;
        13'h1a82: mulA[7:0] <= ss_d;
        13'h1a83: mulA[15:8] <= ss_d;
        13'h1a84: mulY[7:0] <= ss_d;
        13'h1a85: divt[7:0] <= ss_d;
        13'h1a86: divt[15:8] <= ss_d;
        13'h1a87: quotient[7:0] <= ss_d;
        13'h1a88: quotient[8:8] <= ss_d[0:0];
        13'h1a89: remainder[7:0] <= ss_d;
        13'h1a8a: remainder[15:8] <= ss_d;
        default: ;
      endcase
    end else if (!ss_hold || !RST_N) begin
`endif

    if(RST_N == 1'b0) begin
      mulA <= {16{1'b0}};
      mulY <= {8{1'b0}};
      mulRes <= {16{1'b0}};
      divt <= {16{1'b0}};
      remainder <= {16{1'b0}};
      quotient <= {9{1'b0}};
    end else begin
      if(EN == 1'b1) begin
        if(CTRL.secOp == 4'b1110) begin
          mulRes <= mulTemp;
          mulA <= {mulA[14:0],1'b0};
          mulY <= {1'b0,mulY[7:1]};
        end
        else if(CTRL.secOp == 4'b1111) begin
          if(remainder >= divt) begin
            remainder <= remainder - divt;
            quotient <= {quotient[7:0],1'b1};
          end
          else begin
            quotient <= {quotient[7:0],1'b0};
          end
          divt <= {1'b0,divt[15:1]};
        end
        else begin
          mulA <= {8'b00000000,A};
          mulY <= Y;
          mulRes <= {16{1'b0}};
          divt <= {X,8'b00000000};
          remainder <= {Y,A};
          quotient <= {9{1'b0}};
        end
      end
    end

`ifdef SNES_SAVESTATE
    end
`endif
end

always @* begin
    mulTemp = {16{1'b0}};
    if(CTRL.secOp == 4'b1110) begin
      if(mulY[0] == 1'b1) begin
        mulTemp = mulRes + mulA;
      end
      else begin
        mulTemp = mulRes;
      end
      tResult = mulTemp;
      if(mulTemp[15:8] == 0) begin
        tZ = 1'b1;
      end
      else begin
        tZ = 1'b0;
      end
      tV = 1'b0;
      tS = mulTemp[15];
    end
    else if(CTRL.secOp == 4'b1111) begin
      tResult = {remainder[7:0],quotient[7:0]};
      if(quotient[7:0] == 0) begin
        tZ = 1'b1;
      end
      else begin
        tZ = 1'b0;
      end
      tV = quotient[8];
      tS = quotient[7];
    end
    else begin
      tResult = {16{1'b0}};
      tZ = 1'b0;
      tV = 1'b0;
      tS = 1'b0;
    end
end

assign RES = tResult;
assign ZO = tZ;
assign VO = tV;
assign SO = tS;
assign HO = Y[3:0] >= X[3:0] ? 1'b1 : 1'b0;


`ifdef SNES_SAVESTATE
// Register image; RAM and pipeline state are read only while frozen.
always @* begin
    ss_q = 8'b0;
    case (ss_a)
    13'h1a80: ss_q = mulRes[7:0];
    13'h1a81: ss_q = mulRes[15:8];
    13'h1a82: ss_q = mulA[7:0];
    13'h1a83: ss_q = mulA[15:8];
    13'h1a84: ss_q = mulY[7:0];
    13'h1a85: ss_q = divt[7:0];
    13'h1a86: ss_q = divt[15:8];
    13'h1a87: ss_q = quotient[7:0];
    13'h1a88: ss_q = {7'b0, quotient[8:8]};
    13'h1a89: ss_q = remainder[7:0];
    13'h1a8a: ss_q = remainder[15:8];
    default: ;
    endcase
end
`endif
endmodule
