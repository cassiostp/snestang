// Hi-res / pseudo-hi-res pair blending in snes2hdmi (tangcore#23).
// The PPU is played by the testbench with the timing of ppu.v: one dot is 4 master
// clocks, dotclk high for the first 2 (COLOR_OUT is the sub-screen sub-pixel,
// xs = {x, 1'b1}) and low for the last 2 (the main-screen sub-pixel, xs = {x, 1'b0}).
// snes2hdmi used to write the line buffer on the rising edge only, so on a hi-res line
// the main sub-pixel of every pair was dropped.
//
// Checks, against the line buffer itself and, for one uniform picture, the HDMI rgb:
//   normal lines (hires = 0) hold the rising-edge pixel, as before, whether the two
//     sub-pixels agree (what the PPU really sends) or not;
//   hi-res lines hold the per-channel average (sub + main + 1) >> 1 of the pair: an
//     alternating black/white sub-pixel pattern comes out mid grey everywhere, a
//     pseudo-hi-res transparency pair (two pure colours) comes out half-and-half, and
//     a gradient pair matches the average computed here;
//   hires changing mid-line takes effect at a pair boundary, hires changing inside a
//     pair does not split it (the value sampled with the sub sub-pixel governs);
//   pairs sent during hblank are not written;
//   a whole picture of alternating sub-pixels renders as uniform grey through the
//     scaler, with smoothing off and sharp.
// Fails with $fatal on the first mismatch.
`timescale 1ns/1ps

module tb_snes_hires;

    reg clk_pixel = 0, clk = 0;
    always #6.734 clk_pixel = ~clk_pixel;       // 74.25 MHz
    always #23.28 clk = ~clk;                   // 21.477 MHz

    reg        dotclk = 0, hblank = 1, vblank = 0, hires = 0;
    reg [14:0] rgb5 = 0;
    reg [8:0]  xs = 0, ys = 0;
    reg [31:0] vcfg = 0;

    wire [7:0] ovx, ovy;
    wire [2:0] tmds_d_p, tmds_d_n;
    wire       tmds_clk_p, tmds_clk_n;
    wire       pause_sync;

    snes2hdmi dut (
        .clk(clk), .resetn(1'b1),
        .dotclk(dotclk), .hblank(hblank), .vblank(vblank), .rgb5(rgb5), .xs(xs), .ys(ys),
        .hires(hires),
        .overlay(1'b0), .overlay_x(ovx), .overlay_y(ovy), .overlay_color(15'd0),
        .audio_l(16'd0), .audio_r(16'd0), .audio_ready(1'b0), .audio_en(), .pause(1'b0),
        .snes_refresh(1'b0),
        .scanlines(1'b0), .sl_darkness(2'd0), .sl_thick(1'b0), .sl_out(1'b0),
        .video_config(vcfg),
        .clk_pixel(clk_pixel), .clk_5x_pixel(1'b0), .locked(1'b1),
        .std_timing(1'b1),
        .pause_snes_for_frame_sync(pause_sync),
        .tmds_clk_n(tmds_clk_n), .tmds_clk_p(tmds_clk_p), .tmds_d_n(tmds_d_n), .tmds_d_p(tmds_d_p)
    );

    // what the HDMI sink would show: rgb while cx = x + 1 (as in tb_snes_scaler)
    reg [23:0] img [0:1280*720-1];
    always @(posedge clk_pixel)
        if (dut.cy < 10'd720 && dut.cx >= 11'd1 && dut.cx <= 11'd1280)
            img[dut.cy * 1280 + dut.cx - 1] = dut.rgb;

    // BGR5 as the PPU sends it: [14:10] B, [9:5] G, [4:0] R
    function [14:0] bgr(input [4:0] b, input [4:0] g, input [4:0] r);
        bgr = {b, g, r};
    endfunction
    function [4:0] avg5(input [4:0] a, input [4:0] b);
        avg5 = ({1'b0, a} + {1'b0, b} + 6'd1) >> 1;
    endfunction
    function [14:0] blend(input [14:0] a, input [14:0] b);
        blend = {avg5(a[14:10], b[14:10]), avg5(a[9:5], b[9:5]), avg5(a[4:0], b[4:0])};
    endfunction

    // per-column test patterns (deterministic, different in every channel)
    function [14:0] pat_sub(input integer x);
        pat_sub = bgr(x % 32, (x * 3) % 32, (x * 7 + 1) % 32);
    endfunction
    function [14:0] pat_main(input integer x);
        pat_main = bgr(31 - (x % 32), (x * 5 + 2) % 32, (x * 11 + 3) % 32);
    endfunction

    integer errors = 0, checks = 0;
    task expect_mem(input integer line, input integer x, input [14:0] want, input [8*40-1:0] what);
        reg [14:0] got;
        begin
            got = dut.mem[(line % 32) * 256 + x];
            checks = checks + 1;
            if (got !== want) begin
                errors = errors + 1;
                if (errors <= 12)
                    $display("MISMATCH %0s line %0d x %0d: got %b_%b_%b, want %b_%b_%b",
                             what, line, x, got[14:10], got[9:5], got[4:0],
                             want[14:10], want[9:5], want[4:0]);
            end
        end
    endtask

    // one pair as the PPU sends it: sub for 2 clocks (dotclk 1), main for 2 (dotclk 0).
    // hr_sub / hr_main let a case change hires inside the pair.
    task send_pair(input integer x, input [14:0] sub, input [14:0] mn, input hr_sub, input hr_main);
        begin
            @(negedge clk);
            dotclk = 1; rgb5 = sub; xs = {x[7:0], 1'b1}; hires = hr_sub;
            repeat (2) @(posedge clk);
            @(negedge clk);
            dotclk = 0; rgb5 = mn; xs = {x[7:0], 1'b0}; hires = hr_main;
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
            repeat (8) @(posedge clk);         // let the last BRAM write land
        end
    endtask

    integer x, line;
    reg [14:0] S, M;

    // refresh the whole picture area of img from a frame that starts after the call
    task wait_frame;
        begin
            while (dut.cy == 10'd0) @(posedge clk_pixel);
            while (dut.cy != 10'd0) @(posedge clk_pixel);
            while (dut.cy != 10'd730) @(posedge clk_pixel);
        end
    endtask

    localparam [14:0] WHITE = 15'b11111_11111_11111, BLACK = 15'd0;
    localparam [14:0] GREY  = 15'b10000_10000_10000;    // (31 + 0 + 1) >> 1 = 16
    localparam [23:0] GREY8 = 24'h808080;               // GREY through {c, 3'b0}

    initial begin
        dut.pause_snes_for_frame_sync = 1'b0;
        repeat (8) @(posedge clk);

        // ---- normal line, contrived sub != main: the sub (rising-edge) pixel wins, as before
        line = 1;
        start_line(line);
        for (x = 0; x < 256; x = x + 1) send_pair(x, pat_sub(x), pat_main(x), 0, 0);
        end_line;
        for (x = 0; x < 256; x = x + 1) expect_mem(line, x, pat_sub(x), "normal, sub!=main");
        $display("normal line (hires=0) keeps the rising-edge pixel: done");

        // ---- normal line as the PPU sends it, sub == main
        line = 2;
        start_line(line);
        for (x = 0; x < 256; x = x + 1) send_pair(x, pat_main(x), pat_main(x), 0, 0);
        end_line;
        for (x = 0; x < 256; x = x + 1) expect_mem(line, x, pat_main(x), "normal, sub==main");
        $display("normal line (sub==main) unchanged: done");

        // ---- hi-res: alternating sub-pixels. Dropping one side would give a black/white
        // checkerboard; the blend gives mid grey in every column, both phases alike.
        line = 3;
        start_line(line);
        for (x = 0; x < 256; x = x + 1)
            send_pair(x, x[0] ? BLACK : WHITE, x[0] ? WHITE : BLACK, 1, 1);
        end_line;
        for (x = 0; x < 256; x = x + 1) expect_mem(line, x, GREY, "hi-res alternating");
        $display("hi-res alternating sub-pixels blend to grey %b per channel: done", GREY[4:0]);

        // ---- pseudo-hi-res transparency: the sub screen is shown half a pixel left of
        // the main screen; on a CRT the pair blends. Pure blue + pure red -> half of each,
        // and a gradient pair -> the per-channel average (no carry across channels: the
        // patterns put 31 next to 0 in neighbouring channels).
        line = 4;
        start_line(line);
        for (x = 0; x < 256; x = x + 1) begin
            if (x < 128) send_pair(x, bgr(31, 0, 0), bgr(0, 0, 31), 1, 1);
            else         send_pair(x, pat_sub(x), pat_main(x), 1, 1);
        end
        end_line;
        for (x = 0; x < 128; x = x + 1) expect_mem(line, x, bgr(16, 0, 16), "pseudo transparency");
        for (x = 128; x < 256; x = x + 1) expect_mem(line, x, blend(pat_sub(x), pat_main(x)), "hi-res gradient");
        $display("pseudo-hi-res pair (blue sub, red main) gives B=16,G=0,R=16; gradient averaged: done");

        // ---- hires changes mid-line (a mid-frame SETINI / BG-mode raster effect)
        line = 5;
        start_line(line);
        for (x = 0; x < 256; x = x + 1) send_pair(x, pat_sub(x), pat_main(x), x >= 128, x >= 128);
        end_line;
        for (x = 0; x < 128; x = x + 1) expect_mem(line, x, pat_sub(x), "mid-line toggle, first half");
        for (x = 128; x < 256; x = x + 1) expect_mem(line, x, blend(pat_sub(x), pat_main(x)), "mid-line toggle, second half");
        $display("hires toggling mid-line takes effect at the pair boundary: done");

        // ---- hires changes inside a pair: the value with the sub sub-pixel governs
        line = 6;
        start_line(line);
        for (x = 0; x < 256; x = x + 1) send_pair(x, pat_sub(x), pat_main(x), 1, 0);
        end_line;
        for (x = 0; x < 256; x = x + 1) expect_mem(line, x, blend(pat_sub(x), pat_main(x)), "in-pair 1->0");
        line = 7;
        start_line(line);
        for (x = 0; x < 256; x = x + 1) send_pair(x, pat_sub(x), pat_main(x), 0, 1);
        end_line;
        for (x = 0; x < 256; x = x + 1) expect_mem(line, x, pat_sub(x), "in-pair 0->1");
        $display("hires toggling inside a pair does not split it: done");

        // ---- hblank: nothing is written, hi-res or not
        line = 8;
        for (x = 0; x < 256; x = x + 1) dut.mem[(line % 32) * 256 + x] = bgr(3, 5, 7);
        @(negedge clk); ys = line[8:0]; hblank = 1;
        for (x = 0; x < 256; x = x + 1) send_pair(x, WHITE, WHITE, 1, 1);
        end_line;
        for (x = 0; x < 256; x = x + 1) expect_mem(line, x, bgr(3, 5, 7), "hblank");
        $display("pairs during hblank leave the buffer alone: done");

        if (errors != 0) begin
            $display("tb_snes_hires: %0d of %0d line-buffer checks FAILED", errors, checks);
            $fatal(1, "tb_snes_hires: FAIL");
        end
        $display("line buffer: %0d checks ok", checks);

        // ---- end to end: every buffer slot holds the blended grey, so the whole
        // picture must render as uniform grey whatever the scaler does, with
        // smoothing off and then sharp.
        for (line = 0; line < 32; line = line + 1) begin
            start_line(line);
            for (x = 0; x < 256; x = x + 1) send_pair(x, x[0] ? BLACK : WHITE, x[0] ? WHITE : BLACK, 1, 1);
            end_line;
        end
        vcfg = 32'd0;
        wait_frame;
        for (x = 0; x < 9; x = x + 1) begin
            checks = checks + 1;
            if (img[360 * 1280 + 200 + x * 100] !== GREY8) begin
                $display("MISMATCH rendered (smoothing off) at x %0d: got %h, want %h",
                         200 + x * 100, img[360 * 1280 + 200 + x * 100], GREY8);
                errors = errors + 1;
            end
        end
        $display("rendered alternating sub-pixels as uniform grey %h (smoothing off): done", GREY8);
        vcfg = 32'h1 << 18;                     // sharp
        wait_frame;
        wait_frame;                             // the mode latch is at the frame start
        for (x = 0; x < 9; x = x + 1) begin
            checks = checks + 1;
            if (img[360 * 1280 + 200 + x * 100] !== GREY8) begin
                $display("MISMATCH rendered (sharp) at x %0d: got %h, want %h",
                         200 + x * 100, img[360 * 1280 + 200 + x * 100], GREY8);
                errors = errors + 1;
            end
        end
        $display("rendered alternating sub-pixels as uniform grey %h (smoothing sharp): done", GREY8);

        if (errors != 0) begin
            $display("tb_snes_hires: FAIL (%0d errors)", errors);
            $fatal(1, "tb_snes_hires: FAIL");
        end
        $display("tb_snes_hires: PASS (%0d checks)", checks);
        $finish;
    end

    initial begin
        #2000000000;
        $fatal(1, "tb_snes_hires: timeout");
    end
endmodule
