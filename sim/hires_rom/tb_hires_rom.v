// hires_rom bench (tangcore#23): the homebrew ROM's patterns through the scaler.
// Uses the ROM's palette (CGRAM[0] blue, CGRAM[1] red), its stripe tile
// (plane0 0xAA: alternating 1/0) and its H glyph row 0 (0x81: 10000001),
// with PPU timing (sub on dotclk high, main on low, xs = {x, dotclk}).
// Checks the standard 512-wide line buffer holds both halves distinctly and
// hires_lines is set (mode-5 and pseudo-hi-res phases of hires_test.asm).
// The PPU HIGH_RES flag for the ROM's modes (BGMODE 5, BGMODE 1 + SETINI $08)
// is HIRES||PSEUDOHIRES with BLEND tied 0 (ppu.v:906,2330; snestang_top.v:285),
// Verified by reading the RTL and by tb_hires_flag.sv (Verilator, real SPPU).
`timescale 1ns/1ps

module tb_hires_rom;

    reg clk = 0, clk_pixel = 0;
    always #23.28 clk = ~clk;
    always #6.734 clk_pixel = ~clk_pixel;

    reg dotclk = 0, hblank = 1, vblank = 0, hires = 0;
    reg [14:0] rgb5 = 0;
    reg [8:0] xs = 0, ys = 0;
    wire [7:0] ovx, ovy;
    wire [2:0] tmds_d_p, tmds_d_n;
    wire tmds_clk_p, tmds_clk_n, pause_sync;

    snes2hdmi dut (
        .clk(clk), .resetn(1'b1),
        .dotclk(dotclk), .hblank(hblank), .vblank(vblank), .rgb5(rgb5), .xs(xs), .ys(ys),
        .hires(hires),
        .overlay(1'b0), .overlay_x(ovx), .overlay_y(ovy), .overlay_color(15'd0),
        .audio_l(16'd0), .audio_r(16'd0), .audio_ready(1'b0), .audio_en(), .pause(1'b0),
        .snes_refresh(1'b0),
        .scanlines(1'b0), .sl_darkness(2'd0), .sl_thick(1'b0), .sl_out(1'b0),
        .video_config(32'd0),
        .clk_pixel(clk_pixel), .clk_5x_pixel(1'b0), .locked(1'b1),
        .std_timing(1'b1),
        .pause_snes_for_frame_sync(pause_sync),
        .tmds_clk_n(tmds_clk_n), .tmds_clk_p(tmds_clk_p), .tmds_d_n(tmds_d_n), .tmds_d_p(tmds_d_p)
    );

    task send_pair(input integer x, input [14:0] sub, input [14:0] mn);
        begin
            @(negedge clk);
            dotclk = 1; rgb5 = sub; xs = {x[7:0], 1'b1}; hires = 1;
            repeat (2) @(posedge clk);
            @(negedge clk);
            dotclk = 0; rgb5 = mn; xs = {x[7:0], 1'b0}; hires = 1;
            repeat (2) @(posedge clk);
        end
    endtask
    task start_line(input integer line);
        begin
            @(negedge clk);
            hblank = 1; dotclk = 0; ys = line[8:0];
            repeat (4) @(posedge clk);
            @(negedge clk);
            hblank = 0;
        end
    endtask
    task end_line;
        begin
            @(negedge clk);
            hblank = 1; dotclk = 0; hires = 0;
            repeat (8) @(posedge clk);
        end
    endtask

    localparam [14:0] BLUE = 15'b11111_00000_00000, RED = 15'b00000_00000_11111;
    integer errors = 0, checks = 0, x, line;

    initial begin
        dut.pause_snes_for_frame_sync = 1'b0;
        repeat (8) @(posedge clk);

        // stripe tile row: 0xAA plane0 -> pixels 1,0,1,0... -> RED,BLUE,...
        line = 10;
        start_line(line);
        for (x = 0; x < 256; x = x + 1)
            send_pair(x, x[0] ? BLUE : RED, x[0] ? RED : BLUE);
        end_line;
        for (x = 0; x < 256; x = x + 1) begin
            checks = checks + 2;
            if (dut.mem[((line % 32) * 512) + x * 2 + 1] !== (x[0] ? BLUE : RED)) begin
                errors = errors + 1;
                if (errors <= 8) $display("MISMATCH stripe sub x=%0d", x);
            end
            if (dut.mem[((line % 32) * 512) + x * 2] !== (x[0] ? RED : BLUE)) begin
                errors = errors + 1;
                if (errors <= 8) $display("MISMATCH stripe main x=%0d", x);
            end
        end
        checks = checks + 1;
        if (dut.hires_lines[line % 32] !== 1'b1) begin errors = errors + 1; $display("MISMATCH stripe flag"); end
        $display("stripe tile (0xAA) red/blue alternating, flag 1: done");

        // H glyph row 0: 0x81 = 10000001 -> RED,BLUE x6,RED (sub=backdrop blue for pseudo)
        line = 11;
        start_line(line);
        for (x = 0; x < 8; x = x + 1)
            send_pair(x, BLUE, (x == 0 || x == 7) ? RED : BLUE);
        for (x = 8; x < 256; x = x + 1)
            send_pair(x, BLUE, BLUE);
        end_line;
        checks = checks + 4;
        if (dut.mem[((line % 32) * 512) + 0 * 2 + 1] !== BLUE) begin errors = errors + 1; $display("MISMATCH H sub x=0"); end
        if (dut.mem[((line % 32) * 512) + 0 * 2] !== RED) begin errors = errors + 1; $display("MISMATCH H main x=0"); end
        if (dut.mem[((line % 32) * 512) + 1 * 2 + 1] !== BLUE) begin errors = errors + 1; $display("MISMATCH H sub x=1"); end
        if (dut.mem[((line % 32) * 512) + 1 * 2] !== BLUE) begin errors = errors + 1; $display("MISMATCH H main x=1"); end
        if (dut.mem[((line % 32) * 512) + 7 * 2] !== RED) begin errors = errors + 1; $display("MISMATCH H main x=7"); end
        checks = checks + 1;
        $display("H glyph (0x81) backdrop-blue sub, red/blue main: done");

        if (errors != 0) begin
            $display("tb_hires_rom: FAIL (%0d errors, %0d checks)", errors, checks);
            $fatal(1, "tb_hires_rom: FAIL");
        end
        $display("tb_hires_rom: PASS (%0d checks)", checks);
        $finish;
    end

    initial begin
        #1000000000;
        $fatal(1, "tb_hires_rom: timeout");
    end
endmodule
