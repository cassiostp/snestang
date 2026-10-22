// Block RAM backed SNES VRAM implementation
// SNES VRAM is basically two 8-bit SRAMs

module vram (
`ifdef SNES_SAVESTATE
    input ss_hold, ss_sel, ss_req, ss_we,
    input [15:0] ss_addr,
    input [7:0] ss_din,
    output reg ss_ack = 0,
    output reg [7:0] ss_q,
    input [12:0] ss_reg_a,
    input [7:0] ss_reg_d,
    input ss_reg_we,
    output [7:0] ss_reg_q,
`endif
    input clk,

    input [14:0] vram1_addr, // low byte
    input vram1_req,
    output reg vram1_ack,
    input vram1_we,
    input [7:0] vram1_din,   
    output reg [7:0] vram1_dout,

    input [14:0] vram2_addr, // high byte
    input vram2_req,
    output reg vram2_ack,
    input vram2_we,
    input [7:0] vram2_din,   
    output reg [7:0] vram2_dout
);

`ifdef SNES_SAVESTATE
wire [7:0] raw1, raw2;
reg [7:0] saved1, saved2;
reg valid1 = 0, valid2 = 0, ss_old = 0;
assign vram1_dout = valid1 ? saved1 : raw1;
assign vram2_dout = valid2 ? saved2 : raw2;
wire pending = ss_hold && ss_sel && ss_req != ss_ack;
wire [14:0] addr1 = ss_hold ? ss_addr[14:0] : vram1_addr;
wire [14:0] addr2 = ss_hold ? ss_addr[14:0] : vram2_addr;
wire en1 = ss_hold ? (pending && !ss_addr[15]) : (vram1_req != vram1_ack);
wire en2 = ss_hold ? (pending &&  ss_addr[15]) : (vram2_req != vram2_ack);
wire we1 = ss_hold ? ss_we : vram1_we;
wire we2 = ss_hold ? ss_we : vram2_we;
wire [7:0] din1 = ss_hold ? ss_din : vram1_din;
wire [7:0] din2 = ss_hold ? ss_din : vram2_din;
reg [1:0] ss_delay = 0;
always @(posedge clk) begin
    ss_old <= ss_hold;
    if (ss_hold && !ss_old) begin
        saved1 <= vram1_dout;
        saved2 <= vram2_dout;
        valid1 <= 1;
        valid2 <= 1;
    end
    if (!ss_hold) begin
        vram1_ack <= vram1_req;
        vram2_ack <= vram2_req;
        if (en1 && !we1) valid1 <= 0;
        if (en2 && !we2) valid2 <= 0;
    end
    if (!ss_sel) begin ss_ack <= ss_req; ss_delay <= 0; end
    else if (pending) begin
        if (ss_delay == 2) begin
            ss_q <= ss_addr[15] ? raw2 : raw1;
            ss_ack <= ss_req;
            ss_delay <= 0;
        end else ss_delay <= ss_delay + 1'b1;
    end
    if (ss_reg_we) case (ss_reg_a)
    13'h1b48: saved1 <= ss_reg_d;
    13'h1b49: saved2 <= ss_reg_d;
    13'h1b4a: vram1_ack <= ss_reg_d[0];
    13'h1b4b: vram2_ack <= ss_reg_d[0];
    default: ;
    endcase
end
assign ss_reg_q = ss_reg_a == 13'h1b48 ? saved1 : ss_reg_a == 13'h1b49 ? saved2 :
                  ss_reg_a == 13'h1b4a ? {7'b0,vram1_ack} :
                  ss_reg_a == 13'h1b4b ? {7'b0,vram2_ack} : 8'b0;
`ifndef VERILATOR
vram_spb mem1(.clk(clk), .dout(raw1), .oce(), .ce(en1), .reset(1'b0), .wre(we1), .ad(addr1), .din(din1));
vram_spb mem2(.clk(clk), .dout(raw2), .oce(), .ce(en2), .reset(1'b0), .wre(we2), .ad(addr2), .din(din2));
`else
reg [7:0] mema [0:32767];
reg [7:0] memb [0:32767];
reg [7:0] q1, q2;
assign raw1 = q1;
assign raw2 = q2;
always @(posedge clk) begin
    if (en1) begin
        if (we1) mema[addr1] <= din1;
        else q1 <= mema[addr1];
    end
    if (en2) begin
        if (we2) memb[addr2] <= din2;
        else q2 <= memb[addr2];
    end
end
`endif
`else
`ifndef VERILATOR

// Single-port BRAM version

vram_spb mem1(
    .clk(clk), .dout(vram1_dout), .oce(), 
    .ce(vram1_req ^ vram1_ack), .reset(1'b0), .wre(vram1_we),
    .ad(vram1_addr), .din(vram1_din)
);
vram_spb mem2(
    .clk(clk), .dout(vram2_dout), .oce(), 
    .ce(vram2_req ^ vram2_ack), .reset(1'b0), .wre(vram2_we),
    .ad(vram2_addr), .din(vram2_din)
);

always @(posedge clk) begin
    vram1_ack <= vram1_req;
    vram2_ack <= vram2_req;
end

`else
// Simulation model
// Two 32k * 8 mem
reg [7:0] mema [0:32*1024-1];
reg [7:0] memb [0:32*1024-1];

always @(posedge clk) begin
        vram1_ack <= vram1_req;
        vram2_ack <= vram2_req;

end

wire vram1_en = vram1_req ^ vram1_ack;

always @(posedge clk) begin
    if (vram1_en) begin
        if (vram1_we) begin
            mema[vram1_addr] <= vram1_din;
            // $fdisplay(32'h80000002, "vram_write_a: [%x]L <= %x", addra, dina);
        end else 
            vram1_dout <= mema[vram1_addr];
    end
end

wire vram2_en = vram2_req ^ vram2_ack;
always @(posedge clk) begin
    if (vram2_en) begin
        if (vram2_we) begin
            memb[vram2_addr] <= vram2_din;
            // $fdisplay(32'h80000002, "vram_write_b: [%x]H <= %x", addrb, dinb);
        end else
            vram2_dout <= memb[vram2_addr];
    end
end

`endif 

`endif

endmodule