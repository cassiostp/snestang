
// PPU OAM: 512 bytes dual port

module ppuoam (
    input clock,
`ifdef SNES_SAVESTATE
    input ss_hold,
    input [12:0] ss_a,
    input [7:0] ss_d,
    input ss_we,
    output [7:0] ss_q,
`endif
    input [7:0] address_a,
    input [6:0] address_b,
    input [15:0] data_a,
    input [31:0] data_b,
    input wren_a,
    input wren_b,
    output [15:0] q_a,
    output [31:0] q_b
);
`ifdef SNES_SAVESTATE



`ifdef SNES_SAVESTATE
wire ss_sel = ss_a[12:9] == 4'he;
wire [6:0] addr_b = ss_hold ? ss_a[8:2] : address_b;
reg [31:0] ss_word;
wire ss_mem_we = ss_we && ss_sel && ss_a[1:0] == 3;
wire [31:0] dat_b = ss_hold ? {ss_d, ss_word[23:0]} : data_b;
wire we_b = ss_hold ? ss_mem_we : wren_b;
wire we_a = !ss_hold && wren_a;
wire [15:0] raw_a;
wire [31:0] raw_b;
reg [15:0] saved_a;
reg [31:0] saved_b;
reg ss_old = 0, saved_valid = 0;
assign q_a = saved_valid ? saved_a : raw_a;
assign q_b = saved_valid ? saved_b : raw_b;
always @(posedge clock) begin
    ss_old <= ss_hold;
    if (ss_hold && !ss_old) begin
        saved_a <= q_a;
        saved_b <= q_b;
        saved_valid <= 1;
    end
    if (!ss_hold) saved_valid <= 0;
    if (ss_we && ss_sel) begin
        if (ss_a[1:0] == 0) ss_word[7:0] <= ss_d;
        if (ss_a[1:0] == 1) ss_word[15:8] <= ss_d;
        if (ss_a[1:0] == 2) ss_word[23:16] <= ss_d;
    end
    if (ss_we) case (ss_a)
    13'h1b34: saved_a[7:0] <= ss_d[7:0];
    13'h1b35: saved_a[15:8] <= ss_d[7:0];
    13'h1b36: saved_b[7:0] <= ss_d[7:0];
    13'h1b37: saved_b[15:8] <= ss_d[7:0];
    13'h1b38: saved_b[23:16] <= ss_d[7:0];
    13'h1b39: saved_b[31:24] <= ss_d[7:0];
    default: ;
    endcase
end
assign ss_q = ss_a == 13'h1b34 ? 8'(saved_a >> 0) : ss_a == 13'h1b35 ? 8'(saved_a >> 8) : ss_a == 13'h1b36 ? 8'(saved_b >> 0) : ss_a == 13'h1b37 ? 8'(saved_b >> 8) : ss_a == 13'h1b38 ? 8'(saved_b >> 16) : ss_a == 13'h1b39 ? 8'(saved_b >> 24) : ss_sel ? 8'(raw_b >> (ss_a[1:0] * 8)) : 8'b0;
`endif

`ifndef VERILATOR

Gowin_DPB_OAM mem(.douta(raw_a), .doutb(raw_b), .clka(clock), .ocea(), .cea(1'b1), .reseta(1'b0),
            .wrea(we_a), .clkb(clock), .oceb(), .ceb(1'b1), .resetb(1'b0),
            .wreb(we_b), .ada(address_a), .dina(data_a), .adb(addr_b), .dinb(dat_b));

/*
reg [31:0] mem [0:127];
reg [31:0] douta;
reg [31:0] doutb;
wire [4:0] pos_a = {address_a[0], 4'b1111};
assign raw_a = douta[pos_a -: 16];
assign raw_b = doutb;

always @(posedge clock) begin
    douta <= mem[address_a[7:1]];
    if (we_a)
        mem[address_a[7:0]][pos_a -: 16] <= data_a;
end

always @(posedge clock) begin
    doutb <= mem[addr_b];
    if (we_b)
        mem[addr_b] <= dat_b;
end
*/

`else

reg [15:0] mem [0:255];
reg [15:0] douta;
reg [31:0] doutb;
assign raw_a = douta;
assign raw_b = doutb;

always @(posedge clock) begin
    douta <= mem[address_a];
    doutb <= {mem[{addr_b, 1'd1}], mem[{addr_b, 1'd0}]};
    if (we_a) begin
        mem[address_a] <= data_a;
        // $display("OAM[%x] <= %x", address_a, data_a);
    end
    if (we_b) begin
        mem[{addr_b,1'b1}] <= dat_b[31:16];
        mem[{addr_b,1'b0}] <= dat_b[15:0];
        // $display("OAM[%x] <= %x, OAM=[%x] <= %x", {addr_b,1'b0}, dat_b[15:0], {addr_b,1'b1}, dat_b[31:16]);
    end
end

`endif

`else


`ifndef VERILATOR

Gowin_DPB_OAM mem(.douta(q_a), .doutb(q_b), .clka(clock), .ocea(), .cea(1'b1), .reseta(1'b0),
            .wrea(wren_a), .clkb(clock), .oceb(), .ceb(1'b1), .resetb(1'b0),
            .wreb(wren_b), .ada(address_a), .dina(data_a), .adb(address_b), .dinb(data_b));

/*
reg [31:0] mem [0:127];
reg [31:0] douta;
reg [31:0] doutb;
wire [4:0] pos_a = {address_a[0], 4'b1111};
assign q_a = douta[pos_a -: 16];
assign q_b = doutb;

always @(posedge clock) begin
    douta <= mem[address_a[7:1]];
    if (wren_a)
        mem[address_a[7:0]][pos_a -: 16] <= data_a;
end

always @(posedge clock) begin
    doutb <= mem[address_b];
    if (wren_b)
        mem[address_b] <= data_b;
end
*/

`else

reg [15:0] mem [0:255];
reg [15:0] douta;
reg [31:0] doutb;
assign q_a = douta;
assign q_b = doutb;

always @(posedge clock) begin
    douta <= mem[address_a];
    doutb <= {mem[{address_b, 1'd1}], mem[{address_b, 1'd0}]};
    if (wren_a) begin
        mem[address_a] <= data_a;
        // $display("OAM[%x] <= %x", address_a, data_a);
    end
    if (wren_b) begin
        mem[{address_b,1'b1}] <= data_b[31:16];
        mem[{address_b,1'b0}] <= data_b[15:0];
        // $display("OAM[%x] <= %x, OAM=[%x] <= %x", {address_b,1'b0}, data_b[15:0], {address_b,1'b1}, data_b[31:16]);
    end
end

`endif

`endif
endmodule
