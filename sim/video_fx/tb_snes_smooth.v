// The smoothing running inside snes2hdmi (video_config[19:18]). The picture is pseudo-random,
// line l column c is pix(l, c), and is dumped (snes_src.hex) for the model; the 32-line buffer
// is played by the testbench: before every output row the line that row shows and the ones
// above and below it are written into it. For a list of settings the pixels that go into
// video_fx (rgb_pre and its flags) and the pixels that come out, FX_LAT clocks later, are
// logged with their output position on a set of rows across the frame (the top and bottom 50
// rows, and every 7th); model.py check_smooth compares each one with the golden model: which
// source pixels are blended and with what weights, in both modes and both geometries, the
// border and the overlay left alone, the filters and the scanline darkening acting on the
// smoothed picture.
`timescale 1ns/1ps

module tb_snes_smooth;

    localparam FX_LAT = 11;

    reg clk_pixel = 0, clk = 0;
    always #6.734 clk_pixel = ~clk_pixel;       // 74.25 MHz
    always #23.28 clk = ~clk;                   // 21.477 MHz

    reg        sl_on = 0, sl_thick = 0, sl_out = 0, ov = 0;
    reg  [1:0] sl_dark = 0;
    reg [31:0] vcfg = 0;

    wire [7:0] ovx, ovy;
    reg [14:0] ovc, ovc1, ovc2;
    function [14:0] ov_pix(input [7:0] x, input [7:0] y);
        ov_pix = {x[4:0] ^ y[6:2], x[7:3] + y[4:0], y[7:3] ^ x[6:2]};
    endfunction
    always @(posedge clk_pixel) begin
        ovc2 <= ov_pix(ovx, ovy); ovc1 <= ovc2; ovc <= ovc1;
    end

    wire [2:0] tmds_d_p, tmds_d_n;
    wire       tmds_clk_p, tmds_clk_n;
    wire       pause_sync;

    snes2hdmi dut (
        .clk(clk), .resetn(1'b1),
        .dotclk(1'b0), .hblank(1'b1), .vblank(1'b1), .rgb5(15'd0), .xs(9'd0), .ys(9'd0),
        .hires(1'b0),
        .overlay(ov), .overlay_x(ovx), .overlay_y(ovy), .overlay_color(ovc),
        .audio_l(16'd0), .audio_r(16'd0), .audio_ready(1'b0), .audio_en(), .pause(1'b0),
        .snes_refresh(1'b0),
        .scanlines(sl_on), .sl_darkness(sl_dark), .sl_thick(sl_thick), .sl_out(sl_out),
        .video_config(vcfg),
        .clk_pixel(clk_pixel), .clk_5x_pixel(1'b0), .locked(1'b1),
        .std_timing(1'b1),
        .pause_snes_for_frame_sync(pause_sync),
        .tmds_clk_n(tmds_clk_n), .tmds_clk_p(tmds_clk_p), .tmds_d_n(tmds_d_n), .tmds_d_p(tmds_d_p)
    );

    // source line l, column c
    function [14:0] pix(input [7:0] l, input [7:0] c);
        reg [31:0] h;
        begin
            h = ({16'd0, l, c} + 32'h7654321) * 32'd2654435761;
            h = (h ^ (h >> 15)) * 32'd2246822519;
            pix = h[29:15];
        end
    endfunction

    integer i, fc, fk;
    reg [7:0] fx;
    reg [14:0] src [0:224 * 256 - 1];
    initial begin
        #1;
        for (i = 0; i < 224 * 256; i = i + 1)
            src[i] = pix(i[15:8], i[7:0]);
        $writememh("snes_src.hex", src);
        for (i = 0; i < 32 * 256; i = i + 1)
            dut.mem[i] = pix(i[12:8], i[7:0]);
        dut.pause_snes_for_frame_sync = 1'b0;      // no reset value in the scaler (the FPGA starts it at 0)
    end
    always @(posedge clk_pixel) begin
        if (dut.cx == 11'd100) begin
            for (fk = -1; fk <= 1; fk = fk + 1) begin
                fx = dut.yy_s + fk;
                if (fx < 8'd224)
                    for (fc = 0; fc < 256; fc = fc + 1)
                        dut.mem[{fx[4:0], fc[7:0]}] = pix(fx, fc[7:0]);
            end
        end
    end

    // what went into video_fx FX_LAT clocks ago: {darkness, dark, pic, rgb}
    reg [27:0] hist [0:15];
    reg [27:0] now_in, old_in;
    integer logging = 0, nlog = 0, k;
    integer fd;
    reg     in_row;
    always @(negedge clk_pixel) begin
        now_in = {dut.sl_dk, dut.dark_pre, dut.pic_pre, dut.rgb_pre};
        old_in = hist[FX_LAT - 1];
        for (k = 15; k > 0; k = k - 1) hist[k] = hist[k - 1];
        hist[0] = now_in;
        in_row = dut.cy < 10'd720 && (dut.cy < 10'd50 || dut.cy >= 10'd670 || dut.cy % 7 == 0);
        if (logging && in_row && dut.cx < 11'd1280) begin
            $fwrite(fd, "%h %0d %0d %0d %0d %0d 0 0 %h %h\n", vcfg, dut.cx, dut.cy,
                    old_in[24], old_in[25], old_in[27:26], old_in[23:0], dut.rgb);
            nlog = nlog + 1;
        end
    end

    task wait_row730;
        begin
            while (dut.cy == 10'd730) @(posedge clk_pixel);
            while (dut.cy != 10'd730) @(posedge clk_pixel);
        end
    endtask

    // one frame with these settings, logged
    task frame(input on, input out, input thick, input [1:0] dk, input over, input [31:0] cfg);
        begin
            sl_on = on; sl_out = out; sl_thick = thick; sl_dark = dk; ov = over; vcfg = cfg;
            wait_row730;
            $fwrite(fd, "F %0d %0d %0d %0d %0d %h\n", on, out, thick, dk, over, cfg);
            logging = 1;
            wait_row730;
            logging = 0;
            $display("snes_smooth on=%b out=%b thick=%b darkness=%0d overlay=%b video_config=%h logged", on, out, thick, dk, over, cfg);
        end
    endtask

    localparam [31:0] SHARP = 32'h1 << 18, SOFT = 32'h2 << 18, RSVD = 32'h3 << 18;
    localparam [31:0] FX = 3'd2 | (3'd7 << 3) | (3'd2 << 6) | (2'd3 << 9) | (2'd2 << 11) | (2'd1 << 13);   // colour + slot mask

    initial begin
        fd = $fopen("snes_smooth.log", "w");
        wait_row730;
        //    on out thk dk ov  video_config
        frame(0, 0, 0, 0, 0, 32'h0);                       // off: the model's convention is the scaler's
        frame(1, 0, 0, 0, 0, 32'h0);
        frame(0, 0, 0, 0, 0, RSVD);                        // reserved = off
        frame(0, 0, 0, 0, 0, SHARP);                       // 960x720
        frame(0, 0, 0, 0, 0, SOFT);
        frame(1, 0, 0, 1, 0, SHARP);                       // integer scale, 896x672
        frame(1, 0, 1, 2, 0, SOFT | 32'h0001_2000);
        frame(1, 1, 0, 2, 0, SHARP);                       // output rows, 960x720
        frame(1, 1, 1, 1, 0, SOFT);
        frame(0, 0, 0, 0, 0, SHARP | FX);                  // with the other filters
        frame(1, 0, 0, 1, 0, SOFT | FX);
        frame(1, 1, 1, 3, 0, SHARP | 32'h0001_5A91);
        frame(0, 0, 0, 0, 1, SHARP | FX);                  // menu overlay up: untouched
        frame(1, 0, 0, 2, 1, SOFT);
        frame(0, 0, 0, 0, 0, SHARP);                       // and back
        $fclose(fd);
        if (nlog == 0) begin
            $display("tb_snes_smooth: FAIL (nothing logged)");
            $fatal(1, "tb_snes_smooth: FAIL");
        end
        $display("tb_snes_smooth: %0d pixels logged", nlog);
        $finish;
    end

    initial begin
        #2000000000000;
        $fatal(1, "tb_snes_smooth: timeout");
    end
endmodule
