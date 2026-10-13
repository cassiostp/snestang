// Left-edge sprite test for SPPU (tangcore#19), Verilator top.
//
// One 16x16 sprite at X=508 (9-bit; i.e. 4 pixels left of the screen),
// all tile pixels opaque. Its two 8-pixel slivers sit at X=508 and, mod
// 512 as in the SNES_MiSTer VHDL, X=4, so columns 0..11 of the sprite
// line buffer must be written. The pre-fix Verilog evaluated the
// end-of-sprite test (TILE_X + 8) >= 256 in 32 bits, ended the sprite
// after the first sliver, and only columns 0..3 appeared.
//
// OAM/HOAM and the few control registers are poked directly (the CPU
// register interface is not what is under test); the range/time/fetch
// engines and the pixel writer are the real RTL. VRAM reads return FF.
`timescale 1ns/1ps

module tb_ppu_sprite;
    logic clk = 0;
    always #1 clk = ~clk;

    logic rst_n = 0;
    wire [15:0] vram_addra, vram_addrb;
    wire [7:0] vram_dao, vram_dbo;
    wire [7:0] ppu_do;
    wire [14:0] color_out;
    wire [8:0] x_out, y_out;

    SPPU dut (
        .RST_N(rst_n), .CLK(clk), .ENABLE(1'b1), .DIS_SHORTLINE(1'b1),
        .PA(8'b0), .PARD_N(1'b1), .PAWR_N(1'b1), .DI(8'b0), .DO(ppu_do),
        .SYSCLK_CE(1'b0),
        .VRAM_ADDRA(vram_addra), .VRAM_ADDRB(vram_addrb),
        .VRAM_DAI(8'hFF), .VRAM_DBI(8'hFF),
        .VRAM_DAO(vram_dao), .VRAM_DBO(vram_dbo),
        .VRAM_WRA_N(), .VRAM_WRB_N(), .VRAM_RD_N(),
        .EXTLATCH(1'b0), .PAL(1'b0), .BLEND(1'b0),
        .HIGH_RES(), .DOTCLK(), .HBLANK(), .VBLANK(),
        .COLOR_OUT(color_out), .X_OUT(x_out), .Y_OUT(y_out),
        .HDE(), .VDE(), .V224(), .FIELD_OUT(), .INTERLACE(),
        .HSYNC(), .VSYNC(), .FRAME_OUT(), .BG_EN(5'b11111)
    );

    bit seen [256];
    always @(negedge clk)
        if (dut.SPR_PIX_WE_A)
            seen[dut.SPR_PIX_ADDR_A] = 1'b1;

    integer i, errors = 0;
    initial begin
        repeat (10) @(posedge clk);
        rst_n = 1;
        @(negedge clk);
        // 16x16 small sprites, display on
        dut.OBJSIZE = 3'd3;
        dut.FORCE_BLANK = 1'b0;
        dut.MB = 4'hF;
        // every sprite off-screen (Y=240), then sprite 0 at X=508, Y=10
        for (i = 0; i < 256; i = i + 2) begin
            dut.OAM.mem[i]   = {8'hF0, 8'h00};   // {Y, X low}
            dut.OAM.mem[i+1] = 16'h0000;         // {attrs, tile}
        end
        for (i = 0; i < 32; i = i + 1)
            dut.HOAM[i] = 8'h00;
        dut.OAM.mem[0] = {8'd10, 8'd252};        // Y=10, X low byte
        dut.OAM.mem[1] = {2'b00, 2'b11, 3'b000, 1'b0, 8'h00}; // prio 3, tile 0
        dut.HOAM[0] = 8'h01;                     // sprite 0: X bit 8 set, small

        wait (dut.V_CNT == 9'd40);

        $write("sprite line-buffer columns written:");
        for (i = 0; i < 256; i = i + 1)
            if (seen[i]) $write(" %0d", i);
        $write("\n");
        for (i = 0; i < 12; i = i + 1)
            if (!seen[i]) begin
                errors++;
                $display("FAIL: column %0d of the X=508 sprite never written", i);
            end
        for (i = 12; i < 256; i = i + 1)
            if (seen[i]) begin
                errors++;
                $display("FAIL: unexpected sprite pixel at column %0d", i);
            end

        if (errors == 0) begin
            $display("tb_ppu_sprite: PASS");
            $finish;
        end else begin
            $display("tb_ppu_sprite: %0d FAILURES", errors);
            $fatal(1);
        end
    end

    initial begin
        #2000000;
        $display("tb_ppu_sprite: TIMEOUT (V_CNT=%0d)", dut.V_CNT);
        $fatal(1);
    end
endmodule
