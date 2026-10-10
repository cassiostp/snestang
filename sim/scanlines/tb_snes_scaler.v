// snes2hdmi with scanlines, whole frames: the HDMI part is a stub that counts
// cx/cy like the real one (hdmi_stub.v), the picture is the scaler's rgb output.
// The SNES side is played by the testbench: before each output row it puts the
// source line that row should show into the 32-line buffer, so a wrong source
// line shows up as a wrong colour.
// Checks, for each setting, every output row of the frame against the model of
// src/scanlines.v: which source line it shows, border rows, dark rows and the
// darkened colour; the horizontal extent of the picture; and the row where the
// SNES is released to start a frame (hdmi_first_line).
// Fails with $fatal on the first mismatch.
`timescale 1ns/1ps

module tb_snes_scaler;

    reg clk_pixel = 0, clk = 0;
    always #6.734 clk_pixel = ~clk_pixel;       // 74.25 MHz
    always #23.28 clk = ~clk;                   // 21.477 MHz

    reg        sl_on = 0, sl_thick = 0, sl_out = 0, ov = 0;
    reg  [1:0] sl_dark = 0;
    wire [7:0] overlay_x, overlay_y;
    reg [14:0] overlay_color = 15'b10101_01010_11100;   // BGR5
    wire [2:0] tmds_d_p, tmds_d_n;
    wire       tmds_clk_p, tmds_clk_n;
    wire       pause_sync;

    snes2hdmi dut (
        .clk(clk), .resetn(1'b1),
        .dotclk(1'b0), .hblank(1'b1), .vblank(1'b1), .rgb5(15'd0), .xs(9'd0), .ys(9'd0),
        .overlay(ov), .overlay_x(overlay_x), .overlay_y(overlay_y), .overlay_color(overlay_color),
        .audio_l(16'd0), .audio_r(16'd0), .audio_ready(1'b0), .audio_en(), .pause(1'b0),
        .snes_refresh(1'b0),
        .scanlines(sl_on), .sl_darkness(sl_dark), .sl_thick(sl_thick), .sl_out(sl_out), .video_config(32'd0),
        .clk_pixel(clk_pixel), .clk_5x_pixel(1'b0), .locked(1'b1),
        .pause_snes_for_frame_sync(pause_sync),
        .tmds_clk_n(tmds_clk_n), .tmds_clk_p(tmds_clk_p), .tmds_d_n(tmds_d_n), .tmds_d_p(tmds_d_p)
    );

    // what the HDMI sink would show: rgb while cx = x + 1
    reg [23:0] img [0:1280*720-1];
    reg        first_line_seen [0:749];
    always @(posedge clk_pixel) begin
        if (dut.cy < 10'd720 && dut.cx >= 11'd1 && dut.cx <= 11'd1280)
            img[dut.cy * 1280 + dut.cx - 1] = dut.rgb;
        if (dut.cx == 11'd700)
            first_line_seen[dut.cy] = dut.hdmi_first_line;
    end

    localparam BORDER = 24'h303030;
    localparam R = 3, LINES = 224, TOP = 24, GEOM_W = 896, FULL_W = 960;

    // source picture: SNES line l (0..223) has colour src_color(l) (BGR5), or, when
    // by_column is set, column c has colour col_color(c)
    function [14:0] src_color(input integer l);
        reg [4:0] a, b, c;
        begin
            a = 8 + (l * 5) % 23; b = 8 + (l * 7) % 19; c = 8 + (l * 3) % 17;
            src_color = {a, b, c};
        end
    endfunction
    function [14:0] col_color(input integer n);
        reg [4:0] a, b, c;
        begin
            a = 8 + (n % 12) * 2; b = 8 + (n % 12); c = 30 - (n % 12);
            col_color = {a, b, c};
        end
    endfunction
    function [23:0] to_rgb(input [14:0] p);       // as in snes2hdmi
        to_rgb = {p[4:0], 3'b0, p[9:5], 3'b0, p[14:10], 3'b0};
    endfunction

    reg by_column = 0;
    // the source line an output row shows in the current mode, -1 for a border row
    reg cur_geom;
    function integer exp_line(input integer row);
        begin
            if (cur_geom)
                exp_line = (row < TOP || row >= TOP + R * LINES) ? -1 : (row - TOP) / R;
            else
                exp_line = row * LINES / 720;
        end
    endfunction

    // the SNES: the line an output row needs is in the line buffer before the row starts
    integer fl, fc;
    always @(dut.cy) begin
        if (dut.cy < 10'd720) begin
            fl = exp_line(dut.cy);
            if (fl >= 0 && !by_column)
                for (fc = 0; fc < 256; fc = fc + 1)
                    dut.mem[(fl % 32) * 256 + fc] = src_color(fl);
        end
    end

    task load_columns;
        integer sl, c;
        begin
            for (sl = 0; sl < 32; sl = sl + 1)
                for (c = 0; c < 256; c = c + 1)
                    dut.mem[sl * 256 + c] = col_color(c);
        end
    endtask

    function [7:0] dim8(input [7:0] v, input [1:0] d);
        case (d)
        0: dim8 = v - v / 4;
        1: dim8 = v / 2;
        2: dim8 = v / 4;
        default: dim8 = 0;
        endcase
    endfunction

    function [23:0] darken(input [23:0] p, input [1:0] d);
        darken = {dim8(p[23:16], d), dim8(p[15:8], d), dim8(p[7:0], d)};
    endfunction

    // wait for two frame ends after a settings change: the second frame is drawn with
    // the new settings, and img holds it when this returns (in the blanking at row 726)
    task settle;
        begin
            repeat (2) begin
                while (dut.cy != 10'd725) @(posedge clk_pixel);
                while (dut.cy == 10'd725) @(posedge clk_pixel);
            end
        end
    endtask

    task fail(input [8*60-1:0] what, input integer row, input [23:0] got, input [23:0] want);
        begin
            $display("FAIL: %0s at row %0d: got %h, want %h (on=%b out=%b thick=%b dark=%0d ov=%b)",
                     what, row, got, want, sl_on, sl_out, sl_thick, sl_dark, ov);
            $fatal(1, "tb_snes_scaler: FAIL");
        end
    endtask

    integer row, line, rr, nd, XP, x, first, last, runs, runlen, minrun, maxrun, w;
    reg [23:0] want, got, prev;
    reg is_geom;

    task check_rows(input on, input out, input thick, input [1:0] dk, input over);
        begin
            is_geom = on & ~out & ~over;
            nd = thick ? 2 : 1;
            XP = 640;
            for (row = 0; row < 720; row = row + 1) begin
                got = img[row * 1280 + XP];
                line = exp_line(row);
                if (over)
                    want = to_rgb(overlay_color);
                else if (line < 0)
                    want = BORDER;
                else begin
                    want = to_rgb(src_color(line));
                    if (is_geom ? ((row - TOP) % R >= R - nd) : (on & out & ((row % R) >= R - nd)))
                        want = darken(want, dk);
                end
                if (got !== want) fail("picture", row, got, want);
                if (img[row * 1280 + 100] !== BORDER) fail("left border", row, img[row * 1280 + 100], BORDER);
                if (img[row * 1280 + 1200] !== BORDER) fail("right border", row, img[row * 1280 + 1200], BORDER);
            end
            // the SNES is released at the first row of the picture
            for (row = 0; row < 750; row = row + 1)
                if (first_line_seen[row] !== (row == (is_geom ? TOP : 0))) begin
                    $display("FAIL: hdmi_first_line at row %0d is %b (geom=%b)", row, first_line_seen[row], is_geom);
                    $fatal(1, "tb_snes_scaler: FAIL");
                end
        end
    endtask

    // horizontal extent and pixel widths on a row through the middle of the picture
    task check_columns(input geom);
        integer pw;
        begin
            pw = geom ? GEOM_W : FULL_W;
            row = 360;
            first = -1; last = -1; runs = 0; minrun = 99; maxrun = 0; runlen = 0; prev = BORDER;
            for (x = 0; x < 1280; x = x + 1) begin
                got = img[row * 1280 + x];
                if (got !== BORDER) begin
                    if (first < 0) first = x;
                    last = x;
                    if (got !== prev) begin
                        if (runs > 0) begin
                            if (runlen < minrun) minrun = runlen;
                            if (runlen > maxrun) maxrun = runlen;
                        end
                        runs = runs + 1; runlen = 0;
                    end
                    runlen = runlen + 1;
                end
                prev = got;
            end
            w = last - first + 1;
            if (first !== (1280 - pw) / 2 || w !== pw) begin
                $display("FAIL: picture spans x=%0d..%0d (width %0d), want %0d..%0d", first, last, w, (1280 - pw) / 2, (1280 + pw) / 2 - 1);
                $fatal(1, "tb_snes_scaler: FAIL");
            end
            if (minrun < 3 || maxrun > 4) begin
                $display("FAIL: pixel widths %0d..%0d, want 3..4", minrun, maxrun);
                $fatal(1, "tb_snes_scaler: FAIL");
            end
            if (runs !== 256) begin
                $display("FAIL: %0d source columns on the row, want 256", runs);
                $fatal(1, "tb_snes_scaler: FAIL");
            end
        end
    endtask

    task run(input on, input out, input thick, input [1:0] dk, input over);
        begin
            sl_on = on; sl_out = out; sl_thick = thick; sl_dark = dk; ov = over;
            cur_geom = on & ~out & ~over;
            settle;
            check_rows(on, out, thick, dk, over);
            $display("snes2hdmi on=%b out=%b thick=%b darkness=%0d overlay=%b: ok", on, out, thick, dk, over);
        end
    endtask

    initial begin
        cur_geom = 0;
        #1;
        // by row: the vertical geometry and the darkening
        run(0, 0, 0, 2, 0);                     // off: the old geometry
        run(1, 0, 0, 2, 0);                     // the default: integer, thin, 75 %
        run(1, 0, 1, 0, 0);
        run(1, 0, 0, 1, 0);
        run(1, 0, 1, 3, 0);
        run(1, 1, 0, 2, 0);                     // output rows
        run(1, 1, 1, 1, 0);
        run(1, 0, 0, 2, 1);                     // menu up: the overlay is left alone
        run(1, 1, 1, 2, 1);
        run(1, 0, 1, 2, 0);                     // and back
        // by column: the horizontal geometry
        by_column = 1;
        load_columns;
        sl_on = 0; sl_out = 0; ov = 0; cur_geom = 0; settle; check_columns(0);
        $display("snes2hdmi columns, scanlines off: ok");
        sl_on = 1; cur_geom = 1; settle; check_columns(1);
        $display("snes2hdmi columns, integer scale: ok");
        sl_out = 1; cur_geom = 0; settle; check_columns(0);
        $display("snes2hdmi columns, output rows: ok");
        $display("tb_snes_scaler: PASS");
        $finish;
    end

    initial begin
        #2000000000;
        $fatal(1, "tb_snes_scaler: timeout");
    end
endmodule
