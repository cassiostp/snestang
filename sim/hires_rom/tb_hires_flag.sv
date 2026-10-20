// PPU HIGH_RES flag for the homebrew ROM's modes (Verilator, real SPPU).
// Drives the CPU bus as hires_test.asm does and checks HIGH_RES:
//   BGMODE 5 -> 1 (HIRES), BGMODE 1 + SETINI $08 -> 1 (PSEUDOHIRES && ~BLEND),
//   BGMODE 1 + SETINI $00 -> 0. BLEND tied 0 as in snestang_top.v:285.
// Run: sh run_flag.sh (verilator image).
`timescale 1ns/1ps

module tb_hires_flag;
    logic clk = 0;
    always #1 clk = ~clk;

    logic rst_n = 0;
    logic [7:0] pa = 0, di = 0;
    logic pard_n = 1, pawr_n = 1, sysce = 0;
    wire [7:0] ppu_do;
    wire hires, dotclk;
    wire [14:0] color_out;
    wire [8:0] x_out, y_out;

    SPPU dut (
        .RST_N(rst_n), .CLK(clk), .ENABLE(1'b1), .DIS_SHORTLINE(1'b0),
        .PA(pa), .PARD_N(pard_n), .PAWR_N(pawr_n), .DI(di), .DO(ppu_do),
        .SYSCLK_CE(sysce),
        .VRAM_ADDRA(), .VRAM_ADDRB(),
        .VRAM_DAI(8'hFF), .VRAM_DBI(8'hFF),
        .VRAM_DAO(), .VRAM_DBO(),
        .VRAM_WRA_N(), .VRAM_WRB_N(), .VRAM_RD_N(),
        .EXTLATCH(1'b0), .PAL(1'b0), .BLEND(1'b0),
        .HIGH_RES(hires), .DOTCLK(dotclk),
        .HBLANK(), .VBLANK(),
        .COLOR_OUT(color_out), .X_OUT(x_out), .Y_OUT(y_out),
        .HDE(), .VDE(), .V224(), .FIELD_OUT(), .INTERLACE(),
        .HSYNC(), .VSYNC(), .FRAME_OUT(), .BG_EN(5'b11111)
    );

    task automatic ppu_write(input [7:0] addr, input [7:0] data);
        @(negedge clk);
        pa = addr; di = data; pawr_n = 1'b0; sysce = 1'b1;
        @(negedge clk);
        pawr_n = 1'b1; sysce = 1'b0;
        repeat (2) @(negedge clk);
    endtask

    integer errors = 0;
    task automatic check(input bit want, input string what);
        if (hires !== want) begin
            errors++;
            $display("MISMATCH %s HIGH_RES: got %b want %b", what, hires, want);
        end else
            $display("%s HIGH_RES=%b: ok", what, hires);
    endtask

    initial begin
        repeat (10) @(posedge clk);
        rst_n = 1;
        repeat (4) @(negedge clk);
        // ROM mode-5 phase
        ppu_write(8'h05, 8'h05);
        ppu_write(8'h33, 8'h00);
        repeat (4) @(negedge clk);
        check(1'b1, "mode5");
        // ROM pseudo phase
        ppu_write(8'h05, 8'h01);
        ppu_write(8'h33, 8'h08);
        repeat (4) @(negedge clk);
        check(1'b1, "pseudo");
        // normal (Zelda/SMW)
        ppu_write(8'h05, 8'h01);
        ppu_write(8'h33, 8'h00);
        repeat (4) @(negedge clk);
        check(1'b0, "normal");
        // mode 6 also HIRES
        ppu_write(8'h05, 8'h06);
        repeat (4) @(negedge clk);
        check(1'b1, "mode6");
        if (errors == 0) begin
            $display("tb_hires_flag: PASS");
            $finish;
        end else begin
            $display("tb_hires_flag: %0d FAILURES", errors);
            $fatal(1);
        end
    end

    initial begin
        #40000000;
        $display("tb_hires_flag: TIMEOUT");
        $fatal(1);
    end
endmodule
