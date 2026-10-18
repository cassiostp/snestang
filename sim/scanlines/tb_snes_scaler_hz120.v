// snes2hdmi at 480p120 (the hz120 variant), whole frames: the HDMI part is a
// stub that counts cx/cy like the real one (hdmi_stub.v), the picture is the
// scaler's rgb output.
// The SNES side is played by the testbench: before each output row it puts the
// source line that row should show into the frame buffer, so a wrong source
// line shows up as a wrong colour.
// Checks, for each setting, every output row of the frame against the model of
// src/scanlines.v: which source line it shows, border rows, dark rows and the
// darkened colour; the horizontal extent of the picture (640 wide, 2.5 x 2,
// centred in 720x480); and the BFI modes (video_config[21:20]: 0 repeats the
// picture, 1 and 3 are black, 2 is half brightness, the overlay stays lit).
// Scale follows core_config[21] (sl_out): Integer (0) centres 640x448,
// Full (1) stretches over the 480 rows; scanline darkening needs scanlines on.
// Fails with $fatal on the first mismatch.
`timescale 1ns/1ps

module tb_snes_scaler_hz120;

    reg clk_pixel = 0, clk = 0;
    always #9.259 clk_pixel = ~clk_pixel;       // 54 MHz, 480p120
    always #23.28 clk = ~clk;                   // 21.477 MHz

    reg        sl_on = 0, sl_thick = 0, sl_out = 0, ov = 0;
    reg  [1:0] sl_dark = 0;
    reg [31:0] vcfg = 0;
    wire [7:0] overlay_x, overlay_y;
    reg [14:0] overlay_color = 15'b10101_01010_11100;   // BGR5
    wire [2:0] tmds_d_p, tmds_d_n;
    wire       tmds_clk_p, tmds_clk_n;
    wire       pause_sync;

    snes2hdmi dut (
        .clk(clk), .resetn(1'b1),
        .dotclk(1'b0), .hblank(1'b1), .vblank(1'b1), .rgb5(15'd0), .xs(9'd0), .ys(9'd0), .hires(1'b0),
        .overlay(ov), .overlay_x(overlay_x), .overlay_y(overlay_y), .overlay_color(overlay_color),
        .audio_l(16'd0), .audio_r(16'd0), .audio_ready(1'b0), .audio_en(), .pause(1'b0),
        .snes_refresh(1'b0),
        .scanlines(sl_on), .sl_darkness(sl_dark), .sl_thick(sl_thick), .sl_out(sl_out), .video_config(vcfg),
        .clk_pixel(clk_pixel), .clk_5x_pixel(1'b0), .locked(1'b1),
        .std_timing(1'b0),
        .pause_snes_for_frame_sync(pause_sync),
        .tmds_clk_n(tmds_clk_n), .tmds_clk_p(tmds_clk_p), .tmds_d_n(tmds_d_n), .tmds_d_p(tmds_d_p)
    );

    // what the HDMI sink would show: rgb while cx = x + 1
    reg [23:0] img [0:1280*720-1];
    always @(posedge clk_pixel) begin
        if (dut.cy < 10'd480 && dut.cx >= 11'd1 && dut.cx <= 11'd720)
            img[dut.cy * 1280 + dut.cx - 1] = dut.rgb;
    end

    localparam BORDER = 24'h303030;
    localparam R = 2, LINES = 224, TOP = 16, PW = 640, SCREEN = 720;

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
                exp_line = row * LINES / 480;
        end
    endfunction

    // the SNES: the line an output row needs is in the frame buffer before the row starts
    integer fl, fc;
    always @(dut.cy) begin
        if (dut.cy < 10'd480) begin
            fl = exp_line(dut.cy);
            if (fl >= 0 && !by_column)
                for (fc = 0; fc < 256; fc = fc + 1)
                    dut.mem[fl * 256 + fc] = src_color(fl);
        end
    end

    task load_columns;
        integer sl, c;
        begin
            for (sl = 0; sl < 224; sl = sl + 1)
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
    // the new settings, and img holds it when this returns (in the blanking at row 500)
    task settle;
        begin
            repeat (2) begin
                while (dut.cy != 10'd500) @(posedge clk_pixel);
                while (dut.cy == 10'd500) @(posedge clk_pixel);
            end
        end
    endtask

    task fail(input [8*60-1:0] what, input integer row, input [23:0] got, input [23:0] want);
        begin
            $display("FAIL: %0s at row %0d: got %h, want %h (on=%b out=%b thick=%b dark=%0d ov=%b)",
                     what, row, got, want, sl_on, sl_out, sl_thick, sl_dark, ov);
            $fatal(1, "tb_snes_scaler_hz120: FAIL");
        end
    endtask

    // PPM frame dump for the report (720x480 binary P6)
    task dump_frame(input [8*64-1:0] name);
        integer fd, px, py;
        begin
            fd = $fopen(name, "wb");
            $fwrite(fd, "P6\n720 480\n255\n");
            for (py = 0; py < 480; py = py + 1)
                for (px = 0; px < 720; px = px + 1)
                    $fwrite(fd, "%c%c%c", img[py * 1280 + px][23:16], img[py * 1280 + px][15:8], img[py * 1280 + px][7:0]);
            $fclose(fd);
            $display("dumped %0s", name);
        end
    endtask

    integer row, line, rr, nd, XP, x, first, last, runs, runlen, minrun, maxrun, w;
    reg [23:0] want, got, prev;
    reg is_geom;

    task check_rows(input on, input out, input thick, input [1:0] dk, input over);
        begin
            is_geom = ~out & ~over;
            nd = 1;                 // 2 rows per line: thin and thick are the same one dark row
            XP = 360;
            for (row = 0; row < 480; row = row + 1) begin
                got = img[row * 1280 + XP];
                line = exp_line(row);
                if (over)
                    want = to_rgb(overlay_color);
                else if (line < 0)
                    want = BORDER;
                else begin
                    want = to_rgb(src_color(line));
                    if (is_geom ? (on && ((row - TOP) % R >= R - nd)) : (on && out && ((row % R) >= R - nd)))
                        want = darken(want, dk);
                end
                if (got !== want) fail("picture", row, got, want);
                if (img[row * 1280 + 8] !== BORDER) fail("left border", row, img[row * 1280 + 8], BORDER);
                if (img[row * 1280 + 700] !== BORDER) fail("right border", row, img[row * 1280 + 700], BORDER);
            end
        end
    endtask

    // horizontal extent and pixel widths on a row through the middle of the picture
    task check_columns(input geom);
        integer pw;
        begin
            pw = PW;
            row = 240;
            first = -1; last = -1; runs = 0; minrun = 99; maxrun = 0; runlen = 0; prev = BORDER;
            for (x = 0; x < SCREEN; x = x + 1) begin
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
            if (first !== (SCREEN - pw) / 2 || w !== pw) begin
                $display("FAIL: picture spans x=%0d..%0d (width %0d), want %0d..%0d", first, last, w, (SCREEN - pw) / 2, (SCREEN + pw) / 2 - 1);
                $fatal(1, "tb_snes_scaler_hz120: FAIL");
            end
            if (minrun < 2 || maxrun > 3) begin
                $display("FAIL: pixel widths %0d..%0d, want 2..3", minrun, maxrun);
                $fatal(1, "tb_snes_scaler_hz120: FAIL");
            end
            if (runs !== 256) begin
                $display("FAIL: %0d source columns on the row, want 256", runs);
                $fatal(1, "tb_snes_scaler_hz120: FAIL");
            end
        end
    endtask

    task run(input on, input out, input thick, input [1:0] dk, input over);
        begin
            sl_on = on; sl_out = out; sl_thick = thick; sl_dark = dk; ov = over;
            cur_geom = ~out & ~over;
            settle;
            check_rows(on, out, thick, dk, over);
            $display("snes2hdmi on=%b out=%b thick=%b darkness=%0d overlay=%b: ok", on, out, thick, dk, over);
        end
    endtask

    initial begin
        cur_geom = 0;
        #1;
        // by row: the vertical geometry and the darkening
        run(0, 0, 0, 2, 0);                     // Integer scale with scanlines off: integer geometry, no darkening
        dump_frame("frame_integer_nosl.ppm");
        run(0, 1, 0, 2, 0);                     // Full scale with scanlines off
        dump_frame("frame_full_nosl.ppm");
        run(1, 0, 0, 2, 0);                     // the default: integer, thin, 75 %
        dump_frame("frame_integer_sl.ppm");
        run(1, 0, 1, 0, 0);
        run(1, 0, 0, 1, 0);
        run(1, 0, 1, 3, 0);
        run(1, 1, 0, 2, 0);                     // output rows
        dump_frame("frame_full_sl.ppm");
        run(1, 1, 1, 1, 0);
        run(1, 0, 0, 2, 1);                     // menu up: the overlay is left alone
        dump_frame("frame_osd.ppm");
        run(1, 1, 1, 2, 1);
        run(1, 0, 1, 2, 0);                     // and back
        // by column: the horizontal geometry
        by_column = 1;
        load_columns;
        sl_on = 0; sl_out = 0; ov = 0; cur_geom = 1; settle; check_columns(1);
        $display("snes2hdmi columns, Integer scale with scanlines off: ok");
        sl_on = 1; cur_geom = 1; settle; check_columns(1);
        $display("snes2hdmi columns, integer scale: ok");
        sl_out = 1; cur_geom = 0; settle; check_columns(0);
        $display("snes2hdmi columns, output rows: ok");

        // BFI: mode 0 repeats the picture, 1 and 3 are black, 2 is half
        // brightness, and the overlay is lit on every refresh.
        begin : bfi
            reg [23:0] lit, dimc, gotb;
            integer k;
            by_column = 0;
            sl_on = 0; sl_out = 0; ov = 0; cur_geom = 1;
            vcfg = 32'd0; settle;
            lit = to_rgb(src_color(exp_line(100)));
            dimc = {1'b0, lit[23:17], 1'b0, lit[15:9], 1'b0, lit[7:1]};
            if (img[100 * 1280 + 360] !== lit) fail("bfi off", 100, img[100 * 1280 + 360], lit);
            vcfg = 32'd1 << 20;                 // mode 1, black
            for (k = 0; k < 4; k = k + 1) begin
                settle;
                gotb = img[100 * 1280 + 360];
                if (dut.bfi_dark) begin
                    if (gotb !== 24'h0) fail("bfi black", 100, gotb, 24'h0);
                end else if (gotb !== lit)
                    fail("bfi black lit", 100, gotb, lit);
            end
            vcfg = 32'd3 << 20;                 // mode 3 is black on this core
            settle;
            gotb = img[100 * 1280 + 360];
            if (dut.bfi_dark) begin
                if (gotb !== 24'h0) fail("bfi mode3", 100, gotb, 24'h0);
            end else if (gotb !== lit)
                fail("bfi mode3 lit", 100, gotb, lit);
            vcfg = 32'd2 << 20;                 // mode 2, dim
            settle;
            gotb = img[100 * 1280 + 360];
            if (dut.bfi_dark) begin
                if (gotb !== dimc) fail("bfi dim", 100, gotb, dimc);
            end else if (gotb !== lit)
                fail("bfi dim lit", 100, gotb, lit);
            ov = 1; vcfg = 32'd1 << 20; settle; // menu: BFI does not apply
            gotb = img[100 * 1280 + 360];
            if (gotb !== to_rgb(overlay_color)) fail("bfi overlay", 100, gotb, to_rgb(overlay_color));
            $display("snes2hdmi BFI modes 0/1/2/3 and overlay: ok");
        end
        $display("tb_snes_scaler_hz120: PASS");
        $finish;
    end

    initial begin
        #2000000000;
        $fatal(1, "tb_snes_scaler_hz120: timeout");
    end
endmodule
