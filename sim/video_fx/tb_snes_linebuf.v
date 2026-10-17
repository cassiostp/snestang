// Frame buffer at 480p120. A behavioral SNES writes one solid colour per
// frame (the colour is the frame number) and the real snes2hdmi lock
// shows that frame twice. After lock:
//   - both HDMI frames of a pair show the same frame number;
//   - the next pair shows the next frame;
//   - with BFI mode 1 the second frame is black and the first is the picture.
// A clock that cannot lock (console60k at this line length) must keep
// producing frames and must not sit in a halt for a whole frame.
`timescale 1ns/1ps

`ifndef MCLK_HALF_NS
`define MCLK_HALF_NS 23.2498
`endif
`ifndef LOCKED
`define LOCKED 1
`endif

module tb_snes_linebuf;

    reg clk_pixel = 0, clk = 0;
    always #9.259 clk_pixel = ~clk_pixel;
    always #(`MCLK_HALF_NS) clk = ~clk;

    reg [31:0] vcfg = 0;
    wire [7:0] ovx, ovy;
    wire [2:0] tmds_d_p, tmds_d_n;
    wire tmds_clk_p, tmds_clk_n;
    wire pause_sync;

    reg [8:0] line_no = 0;
    reg [10:0] line_cnt = 0;
    reg [7:0] out_y = 0;
    reg field = 0;
    reg dotclk = 0;
    reg refresh = 0;
    reg [14:0] rgb5 = 0;
    reg [8:0] xs = 0;
    reg hblank = 1;
    reg [15:0] wr_frame = 0;
    wire [10:0] line_len = (line_no == 240 && field) ? 11'd1360 : 11'd1364;

    snes2hdmi dut (
        .clk(clk), .resetn(1'b1),
        .dotclk(dotclk), .hblank(hblank), .vblank(line_no > 224), .rgb5(rgb5),
        .xs(xs), .ys({field, out_y}), .hires(1'b0),
        .overlay(1'b0), .overlay_x(ovx), .overlay_y(ovy), .overlay_color(15'd0),
        .audio_l(16'd0), .audio_r(16'd0), .audio_ready(1'b0), .audio_en(),
        .pause(1'b0), .snes_refresh(refresh),
        .scanlines(1'b0), .sl_darkness(2'd0), .sl_thick(1'b0), .sl_out(1'b0),
        .video_config(vcfg),
        .clk_pixel(clk_pixel), .clk_5x_pixel(1'b0), .locked(1'b1),
        .std_timing(1'b0),
        .pause_snes_for_frame_sync(pause_sync),
        .tmds_clk_n(tmds_clk_n), .tmds_clk_p(tmds_clk_p),
        .tmds_d_n(tmds_d_n), .tmds_d_p(tmds_d_p)
    );

    initial begin
        dut.pause_snes_for_frame_sync = 0;
        dut.sync_done = 0;
        dut.fl_missed = 0;
        dut.pause_sync = 0;
        dut.hdmi_first_line = 0;
        dut.hdmi_first_line_r = 0;
        dut.hdmi_first_line_rr = 0;
    end

    // one pixel is 4 mclk, as the PPU sends it: dotclk high for 2 (the sub
    // sub-pixel) and low for 2 (the main). The scaler writes the pair on
    // the falling edge, one cycle after we drop dotclk.
    always @(posedge clk) begin
        refresh <= (line_cnt < 40);
        if (!pause_sync) begin
            if (line_cnt < 1024 && out_y < 224) begin
                hblank <= 0;
                dotclk <= (line_cnt[1:0] < 2);
                xs <= {line_cnt[9:2], (line_cnt[1:0] < 2)};
                rgb5 <= {wr_frame[4:0], out_y[4:0], 5'd16};
            end else begin
                hblank <= 1;
                dotclk <= 0;
            end
            if (line_cnt == line_len - 1) begin
                line_cnt <= 0;
                if (line_no >= 1 && line_no <= 224)
                    out_y <= out_y + 1;
                if (line_no == 261) begin
                    line_no <= 0;
                    out_y <= 0;
                    field <= ~field;
                    wr_frame <= wr_frame + 1;
                end else
                    line_no <= line_no + 1;
            end else
                line_cnt <= line_cnt + 1;
        end
    end

    integer hdmi_n = 0;
    integer halt_now = 0, halt_max = 0;
    reg [9:0] prev_cy = 0;
    reg [23:0] sample;
    reg [4:0] seen_id;
    reg got;
    reg [4:0] pair_id, prev_id;
    reg pair_valid, have_prev;
    integer pairs = 0, bad = 0;

    always @(posedge clk) begin
        if (pause_sync) begin
            halt_now <= halt_now + 1;
        end else begin
            if (halt_now > halt_max && wr_frame >= 3)
                halt_max <= halt_now;
            halt_now <= 0;
        end
    end

    // centre of the stretched picture: row 200, the column at x=360
    always @(posedge clk_pixel) begin
        if (dut.cy == 10'd200 && dut.cx == 11'd361)
            sample <= dut.rgb;
        if (dut.cy == 0 && prev_cy == 524) begin
            hdmi_n <= hdmi_n + 1;
            if (hdmi_n >= 4) begin
                seen_id = sample[7:3];
                if (`LOCKED && hdmi_n < 8)
                    $display("hdmi %0d bfi_ins=%b rgb=%h id=%0d", hdmi_n, dut.bfi_ins, sample, seen_id);
                if (`LOCKED) begin
                    if (dut.bfi_ins == 1'b0) begin
                        pair_id <= seen_id;
                        pair_valid <= 1;
                    end else if (pair_valid) begin
                        if (seen_id != pair_id) begin
                            bad <= bad + 1;
                            if (bad < 4)
                                $display("FAIL pair %0d ids %0d then %0d", pairs, pair_id, seen_id);
                        end
                        if (have_prev && seen_id != prev_id + 5'd1) begin
                            bad <= bad + 1;
                            if (bad < 4)
                                $display("FAIL pair step %0d -> %0d", prev_id, seen_id);
                        end
                        prev_id <= seen_id;
                        have_prev <= 1;
                        pairs <= pairs + 1;
                    end
                end
            end
            if (hdmi_n == 16) begin
                $display("SUMMARY locked=%0d pairs=%0d bad=%0d halt_max=%0d frames=%0d",
                         `LOCKED, pairs, bad, halt_max, wr_frame);
                if (halt_max > 20000)
                    $fatal(1, "FAIL halt stretched to %0d mclk", halt_max);
                if (`LOCKED && (pairs < 4 || bad != 0))
                    $fatal(1, "FAIL frame buffer pairs=%0d bad=%0d", pairs, bad);
                if (!`LOCKED && wr_frame < 6)
                    $fatal(1, "FAIL free-run produced only %0d frames", wr_frame);
                $display("PASS snes-framebuffer");
                $finish;
            end
        end
        prev_cy <= dut.cy;
    end

    initial begin
        #500000000;
        $fatal(1, "tb_snes_linebuf timeout");
    end
endmodule
