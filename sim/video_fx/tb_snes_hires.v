// Hi-res / pseudo-hi-res in snes2hdmi (tangcore#23).
// The PPU is played by the testbench with the timing of ppu.v: one dot is 4 master
// clocks, dotclk high for the first 2 (COLOR_OUT is the sub-screen sub-pixel,
// xs = {x, 1'b1}) and low for the last 2 (the main-screen sub-pixel, xs = {x, 1'b0}).
//
// hz120 (480p120): hi-res lines hold the per-channel average (sub + main + 1) >> 1
// of the pair in the 256-wide frame buffer (512-wide does not fit: 279/340 BSRAM,
// doubled ~330/340). An alternating pattern blends to grey, pseudo transparency
// to half-and-half; hires takes effect at pair boundaries; hblank pairs are dropped;
// a whole alternating picture renders as uniform grey.
//
// standard (720p): 512-wide line buffer. Each sub-pixel is stored at its own xs
// (sub at {x,1}, main at {x,0}). Normal lines (hires = 0, sub == main from the real
// PPU) read back as 256 via the sub half, bit-identical to before. Hi-res lines
// (BG mode 5/6, pseudo-hi-res) read back as 512 at full resolution: Full 1280 wide
// (2.5x), Integer 1024 centred (2x). hires_lines records HIGH_RES per buffer line,
// committed with the pair, so a mid-line toggle takes effect on the next line.
// A whole alternating picture renders as alternating columns, not grey.
// Fails with $fatal on the first mismatch.
`timescale 1ns/1ps

module tb_snes_hires;

    reg clk_pixel = 0, clk = 0;
`ifdef HZ120
    always #9.259 clk_pixel = ~clk_pixel;       // 54 MHz, 480p120
`else
    always #6.734 clk_pixel = ~clk_pixel;       // 74.25 MHz
`endif
    always #23.28 clk = ~clk;                   // 21.477 MHz

    reg        dotclk = 0, hblank = 1, vblank = 0, hires = 0;
    reg [14:0] rgb5 = 0;
    reg [8:0]  xs = 0, ys = 0;
    reg [31:0] vcfg = 0;
    reg tb_sl_out = 1'b0;

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
        .scanlines(1'b0), .sl_darkness(2'd0), .sl_thick(1'b0), .sl_out(tb_sl_out),
        .video_config(vcfg),
        .clk_pixel(clk_pixel), .clk_5x_pixel(1'b0), .locked(1'b1),
        .std_timing(1'b1),
        .pause_snes_for_frame_sync(pause_sync),
        .tmds_clk_n(tmds_clk_n), .tmds_clk_p(tmds_clk_p), .tmds_d_n(tmds_d_n), .tmds_d_p(tmds_d_p)
    );

    // what the HDMI sink would show: rgb while cx = x + 1 (as in tb_snes_scaler)
    reg [23:0] img [0:1280*720-1];
    always @(posedge clk_pixel)
`ifdef HZ120
        if (dut.cy < 10'd480 && dut.cx >= 11'd1 && dut.cx <= 11'd720)
`else
        if (dut.cy < 10'd720 && dut.cx >= 11'd1 && dut.cx <= 11'd1280)
`endif
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
`ifdef HZ120
    task expect_mem(input integer line, input integer x, input [14:0] want, input [8*40-1:0] what);
        reg [14:0] got;
        begin
            got = dut.mem[line * 256 + x];
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
`else
    // standard 512-wide: xs 9 bits, line holds 512 sub-pixels at (line%32)*512+xs.
    // sub of OUT_X x at xs = x*2+1, main at xs = x*2.
    task expect_sub(input integer line, input integer x, input [14:0] want, input [8*40-1:0] what);
        reg [14:0] got;
        begin
            got = dut.mem[((line % 32) * 512) + (x * 2 + 1)];
            checks = checks + 1;
            if (got !== want) begin
                errors = errors + 1;
                if (errors <= 12)
                    $display("MISMATCH %0s line %0d sub x %0d: got %b_%b_%b, want %b_%b_%b",
                             what, line, x, got[14:10], got[9:5], got[4:0],
                             want[14:10], want[9:5], want[4:0]);
            end
        end
    endtask
    task expect_main(input integer line, input integer x, input [14:0] want, input [8*40-1:0] what);
        reg [14:0] got;
        begin
            got = dut.mem[((line % 32) * 512) + (x * 2)];
            checks = checks + 1;
            if (got !== want) begin
                errors = errors + 1;
                if (errors <= 12)
                    $display("MISMATCH %0s line %0d main x %0d: got %b_%b_%b, want %b_%b_%b",
                             what, line, x, got[14:10], got[9:5], got[4:0],
                             want[14:10], want[9:5], want[4:0]);
            end
        end
    endtask
    task expect_hires(input integer line, input integer want, input [8*40-1:0] what);
        begin
            checks = checks + 1;
            if (dut.hires_lines[line % 32] !== want) begin
                errors = errors + 1;
                if (errors <= 12)
                    $display("MISMATCH %0s line %0d hires flag: got %b, want %b",
                             what, line, dut.hires_lines[line % 32], want);
            end
        end
    endtask
`endif

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
`ifdef HZ120
            while (dut.cy != 10'd500) @(posedge clk_pixel);
`else
            while (dut.cy != 10'd730) @(posedge clk_pixel);
`endif
        end
    endtask

    localparam [14:0] WHITE = 15'b11111_11111_11111, BLACK = 15'd0;
    localparam [14:0] GREY  = 15'b10000_10000_10000;    // (31 + 0 + 1) >> 1 = 16
    localparam [23:0] GREY8 = 24'h808080;               // GREY through {c, 3'b0}
    localparam [23:0] WHITE8 = 24'hF8F8F8, BLACK8 = 24'h000000;

    initial begin
        dut.pause_snes_for_frame_sync = 1'b0;
        repeat (8) @(posedge clk);

`ifdef HZ120
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

        // ---- hi-res: alternating sub-pixels blend to grey
        line = 3;
        start_line(line);
        for (x = 0; x < 256; x = x + 1)
            send_pair(x, x[0] ? BLACK : WHITE, x[0] ? WHITE : BLACK, 1, 1);
        end_line;
        for (x = 0; x < 256; x = x + 1) expect_mem(line, x, GREY, "hi-res alternating");
        $display("hi-res alternating sub-pixels blend to grey %b per channel: done", GREY[4:0]);

        // ---- pseudo-hi-res transparency
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

        // ---- hires changes mid-line
        line = 5;
        start_line(line);
        for (x = 0; x < 256; x = x + 1) send_pair(x, pat_sub(x), pat_main(x), x >= 128, x >= 128);
        end_line;
        for (x = 0; x < 128; x = x + 1) expect_mem(line, x, pat_sub(x), "mid-line toggle, first half");
        for (x = 128; x < 256; x = x + 1) expect_mem(line, x, blend(pat_sub(x), pat_main(x)), "mid-line toggle, second half");
        $display("hires toggling mid-line takes effect at the pair boundary: done");

        // ---- hires changes inside a pair
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
        for (x = 0; x < 256; x = x + 1) dut.mem[line * 256 + x] = bgr(3, 5, 7);
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

        // ---- end to end: uniform grey through the scaler
        for (line = 0; line < 224; line = line + 1) begin
            start_line(line);
            for (x = 0; x < 256; x = x + 1) send_pair(x, x[0] ? BLACK : WHITE, x[0] ? WHITE : BLACK, 1, 1);
            end_line;
        end
        vcfg = 32'd0;
        wait_frame;
        for (x = 0; x < 9; x = x + 1) begin
            checks = checks + 1;
            if (img[200 * 1280 + 80 + x * 60] !== GREY8) begin
                $display("MISMATCH rendered (no smoothing) at x %0d: got %h, want %h",
                         80 + x * 60, img[200 * 1280 + 80 + x * 60], GREY8);
                errors = errors + 1;
            end
        end
        $display("rendered alternating sub-pixels as uniform grey %h (no smoothing): done", GREY8);
`else
        // ---- standard 512-wide ----
        // normal line, contrived sub != main: both halves stored, flag 0.
        // The real PPU sends sub == main when hires = 0; the read uses the sub half.
        line = 1;
        start_line(line);
        for (x = 0; x < 256; x = x + 1) send_pair(x, pat_sub(x), pat_main(x), 0, 0);
        end_line;
        for (x = 0; x < 256; x = x + 1) expect_sub(line, x, pat_sub(x), "normal sub");
        for (x = 0; x < 256; x = x + 1) expect_main(line, x, pat_main(x), "normal main");
        expect_hires(line, 0, "normal flag");
        $display("normal line stores both halves, flag 0: done");

        // ---- normal line as the PPU sends it, sub == main: both halves equal
        line = 2;
        start_line(line);
        for (x = 0; x < 256; x = x + 1) send_pair(x, pat_main(x), pat_main(x), 0, 0);
        end_line;
        for (x = 0; x < 256; x = x + 1) expect_sub(line, x, pat_main(x), "normal sub==main");
        for (x = 0; x < 256; x = x + 1) expect_main(line, x, pat_main(x), "normal main==sub");
        expect_hires(line, 0, "normal flag");
        $display("normal line (sub==main) stores duplicates, flag 0: done");

        // ---- hi-res alternating: distinct sub-pixels, flag 1 (no blending)
        line = 3;
        start_line(line);
        for (x = 0; x < 256; x = x + 1)
            send_pair(x, x[0] ? BLACK : WHITE, x[0] ? WHITE : BLACK, 1, 1);
        end_line;
        for (x = 0; x < 256; x = x + 1) expect_sub(line, x, x[0] ? BLACK : WHITE, "hires sub");
        for (x = 0; x < 256; x = x + 1) expect_main(line, x, x[0] ? WHITE : BLACK, "hires main");
        expect_hires(line, 1, "hires flag");
        $display("hi-res alternating stores distinct sub-pixels, flag 1: done");

        // ---- pseudo-hi-res: blue sub, red main stored distinctly (emulator 512)
        line = 4;
        start_line(line);
        for (x = 0; x < 256; x = x + 1) begin
            if (x < 128) send_pair(x, bgr(31, 0, 0), bgr(0, 0, 31), 1, 1);
            else         send_pair(x, pat_sub(x), pat_main(x), 1, 1);
        end
        end_line;
        for (x = 0; x < 128; x = x + 1) expect_sub(line, x, bgr(31, 0, 0), "pseudo sub");
        for (x = 0; x < 128; x = x + 1) expect_main(line, x, bgr(0, 0, 31), "pseudo main");
        for (x = 128; x < 256; x = x + 1) expect_sub(line, x, pat_sub(x), "gradient sub");
        for (x = 128; x < 256; x = x + 1) expect_main(line, x, pat_main(x), "gradient main");
        expect_hires(line, 1, "pseudo flag");
        $display("pseudo-hi-res stores blue sub / red main distinctly, flag 1: done");

        // ---- mid-line toggle: pixels stored per pair, flag follows the last pair
        line = 5;
        start_line(line);
        for (x = 0; x < 256; x = x + 1) send_pair(x, pat_sub(x), pat_main(x), x >= 128, x >= 128);
        end_line;
        for (x = 0; x < 256; x = x + 1) expect_sub(line, x, pat_sub(x), "mid-line sub");
        for (x = 0; x < 256; x = x + 1) expect_main(line, x, pat_main(x), "mid-line main");
        expect_hires(line, 1, "mid-line flag follows last pair");
        $display("mid-line toggle stored per pair, flag follows last pair (next line): done");

        // ---- in-pair toggle: sub_hires governs the flag, pixels still stored per half
        line = 6;
        start_line(line);
        for (x = 0; x < 256; x = x + 1) send_pair(x, pat_sub(x), pat_main(x), 1, 0);
        end_line;
        for (x = 0; x < 256; x = x + 1) expect_sub(line, x, pat_sub(x), "in-pair 1->0 sub");
        for (x = 0; x < 256; x = x + 1) expect_main(line, x, pat_main(x), "in-pair 1->0 main");
        expect_hires(line, 1, "in-pair 1->0 flag");
        line = 7;
        start_line(line);
        for (x = 0; x < 256; x = x + 1) send_pair(x, pat_sub(x), pat_main(x), 0, 1);
        end_line;
        for (x = 0; x < 256; x = x + 1) expect_sub(line, x, pat_sub(x), "in-pair 0->1 sub");
        for (x = 0; x < 256; x = x + 1) expect_main(line, x, pat_main(x), "in-pair 0->1 main");
        expect_hires(line, 0, "in-pair 0->1 flag");
        $display("in-pair toggle: sub governs the flag, halves still stored: done");

        // ---- hblank: nothing is written
        line = 8;
        for (x = 0; x < 512; x = x + 1) dut.mem[((line % 32) * 512) + x] = bgr(3, 5, 7);
        dut.hires_lines[line % 32] = 1'b0;
        @(negedge clk); ys = line[8:0]; hblank = 1;
        for (x = 0; x < 256; x = x + 1) send_pair(x, WHITE, WHITE, 1, 1);
        end_line;
        for (x = 0; x < 256; x = x + 1) expect_sub(line, x, bgr(3, 5, 7), "hblank sub");
        for (x = 0; x < 256; x = x + 1) expect_main(line, x, bgr(3, 5, 7), "hblank main");
        expect_hires(line, 0, "hblank flag");
        $display("pairs during hblank leave the buffer alone: done");

        if (errors != 0) begin
            $display("tb_snes_hires: %0d of %0d line-buffer checks FAILED", errors, checks);
            $fatal(1, "tb_snes_hires: FAIL");
        end
        $display("line buffer: %0d checks ok", checks);

        // ---- end to end Integer (sl_out=0): 512 sub-pixels to 1024 (2x), centred.
        // Alternating BLACK/WHITE sub-pixels render as alternating columns (2 out
        // pixels per sub-pixel), not uniform grey. Borders 0..127 and 1152..1279.
        tb_sl_out = 1'b0;
        for (line = 0; line < 32; line = line + 1) begin
            start_line(line);
            for (x = 0; x < 256; x = x + 1) send_pair(x, x[0] ? BLACK : WHITE, x[0] ? WHITE : BLACK, 1, 1);
            end_line;
        end
        vcfg = 32'd0;
        wait_frame;
        begin
            integer nblack, nwhite, xi;
            nblack = 0; nwhite = 0;
            for (xi = 128; xi < 1152; xi = xi + 1) begin
                checks = checks + 1;
                if (img[360 * 1280 + xi] === BLACK8) nblack = nblack + 1;
                else if (img[360 * 1280 + xi] === WHITE8) nwhite = nwhite + 1;
                else begin
                    if (errors <= 12)
                        $display("MISMATCH rendered Integer at x %0d: got %h, want black or white", xi, img[360 * 1280 + xi]);
                    errors = errors + 1;
                end
            end
            if (nblack != 512 || nwhite != 512) begin
                $display("MISMATCH Integer hires: want 512 black + 512 white, got black=%0d white=%0d", nblack, nwhite);
                errors = errors + 1;
            end else
                $display("Integer hires renders 2x alternating (black=%0d white=%0d of 1024): done", nblack, nwhite);
            checks = checks + 2;
            if (img[360 * 1280 + 0] !== 24'h303030) begin
                $display("MISMATCH Integer hires left border: got %h, want 303030", img[360 * 1280 + 0]);
                errors = errors + 1;
            end
            if (img[360 * 1280 + 1279] !== 24'h303030) begin
                $display("MISMATCH Integer hires right border: got %h, want 303030", img[360 * 1280 + 1279]);
                errors = errors + 1;
            end
        end
        // ---- end to end Full (sl_out=1): 512 to 1280 (2.5x), fills the width.
        tb_sl_out = 1'b1;
        for (line = 0; line < 32; line = line + 1) begin
            start_line(line);
            for (x = 0; x < 256; x = x + 1) send_pair(x, x[0] ? BLACK : WHITE, x[0] ? WHITE : BLACK, 1, 1);
            end_line;
        end
        wait_frame;
        begin
            integer nblack, nwhite, xi;
            nblack = 0; nwhite = 0;
            for (xi = 0; xi < 1280; xi = xi + 1) begin
                checks = checks + 1;
                if (img[360 * 1280 + xi] === BLACK8) nblack = nblack + 1;
                else if (img[360 * 1280 + xi] === WHITE8) nwhite = nwhite + 1;
                else begin
                    if (errors <= 12)
                        $display("MISMATCH rendered Full at x %0d: got %h, want black or white", xi, img[360 * 1280 + xi]);
                    errors = errors + 1;
                end
            end
            if (nblack == 0 || nwhite == 0) begin
                $display("MISMATCH Full hires: picture is not alternating (black=%0d white=%0d)", nblack, nwhite);
                errors = errors + 1;
            end else
                $display("Full hires renders alternating columns (black=%0d white=%0d of 1280): done", nblack, nwhite);
        end
`endif

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
