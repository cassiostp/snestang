
// PPU CGRAM: 256 * 15 bits

module ppucgram (
    input clock,
`ifdef SNES_SAVESTATE
    input ss_hold,
    input [12:0] ss_a,
    input [7:0] ss_d,
    input ss_we,
    output [7:0] ss_q,
`endif
    input [7:0] address_a,
    input [7:0] address_b,
    input [14:0] data_a,
    input [14:0] data_b,
    input wren_a,
    input wren_b,
    output [14:0] q_a,
    output [14:0] q_b
);


`ifdef SNES_SAVESTATE
wire ss_sel = ss_a[12:9] == 4'hf;
wire [7:0] addr_b = ss_hold ? ss_a[8:1] : address_b;
reg [14:0] ss_word;
wire ss_mem_we = ss_we && ss_sel && ss_a[0] == 1;
wire [14:0] dat_b = ss_hold ? {ss_d[6:0], ss_word[7:0]} : data_b;
wire we_b = ss_hold ? ss_mem_we : wren_b;
wire we_a = !ss_hold && wren_a;
wire [14:0] raw_a;
wire [14:0] raw_b;
reg [14:0] saved_a;
reg [14:0] saved_b;
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
        if (ss_a[0] == 0) ss_word[7:0] <= ss_d;
    end
    if (ss_we) case (ss_a)
    13'h1b30: saved_a[7:0] <= ss_d[7:0];
    13'h1b31: saved_a[14:8] <= ss_d[6:0];
    13'h1b32: saved_b[7:0] <= ss_d[7:0];
    13'h1b33: saved_b[14:8] <= ss_d[6:0];
    default: ;
    endcase
end
assign ss_q = ss_a == 13'h1b30 ? 8'(saved_a >> 0) : ss_a == 13'h1b31 ? 8'(saved_a >> 8) : ss_a == 13'h1b32 ? 8'(saved_b >> 0) : ss_a == 13'h1b33 ? 8'(saved_b >> 8) : ss_sel ? 8'(raw_b >> (ss_a[0] * 8)) : 8'b0;
`endif

`ifndef SNES_SAVESTATE
wire [14:0] raw_a;
wire [14:0] raw_b;
assign q_a = raw_a;
assign q_b = raw_b;
wire [7:0] addr_b = address_b;
wire [14:0] dat_b = data_b;
wire we_a = wren_a, we_b = wren_b;
`endif
`ifndef VERILATOR

gowin_dpb_cgram mem(.douta(raw_a), .doutb(raw_b), .clka(clock), .ocea(), .cea(1'b1), .reseta(1'b0),
            .wrea(we_a), .clkb(clock), .oceb(), .ceb(1'b1), .resetb(1'b0),
            .wreb(we_b), .ada(address_a), .dina(data_a), .adb(addr_b), .dinb(dat_b));

`else

reg [14:0] mem [0:255];
reg [14:0] douta;
reg [14:0] doutb;
assign raw_a = douta;
assign raw_b = doutb;

always @(posedge clock) begin
    douta <= mem[address_a];
    doutb <= mem[addr_b];
    if (we_a) begin
        mem[address_a] <= data_a;
        // $display("CGRAM[%x] <= %x", address_a, data_a);
    end
    if (we_b) begin
        mem[addr_b] <= dat_b;
        // $display("CGRAM[%x] <= %x", addr_b, dat_b);
    end
end

`endif

endmodule
