// Frame-sync halt-lock bench: real snes2hdmi + hdmi stub at the native
// 1647-clock line, against a behavioral SNES (1364 mclk/line, 1360 on
// line 240 of odd frames; OUT_Y as ppu.v counts it; refresh pulse once
// a line; frozen while pause_snes_for_frame_sync is asserted, the way
// enable=0 does in the top). No pixels: this bench is about time.
//
// It checks, per configuration (board mclk via MCLK_HALF_NS, lines per
// field via LINES_EVEN/LINES_ODD):
//   - lockable (SNES free-run faster than HDMI): exactly one SNES frame
//     per HDMI frame, one halt per frame, halt length reported;
//   - not lockable (interlaced 263-line fields, or a slow crystal):
//     the SNES must keep running at its free-run rate. A single halt
//     must never stretch to a whole frame (the missed-release trap:
//     halt engages just after hdmi_first_line and waits a full frame,
//     halving the game speed).
//
// Run (from this directory): ./run.sh
`timescale 1ns/1ps

`ifndef MCLK_HALF_NS
`define MCLK_HALF_NS 23.2727
`endif
`ifndef LINES_EVEN
`define LINES_EVEN 262
`endif
`ifndef LINES_ODD
`define LINES_ODD 262
`endif
`ifndef LOCKED
`define LOCKED 1
`endif

module tb_snes_framelock;

    reg clk_pixel = 0, clk = 0;
    always #9.259 clk_pixel = ~clk_pixel;       // 54 MHz, 480p120
    always #(`MCLK_HALF_NS) clk = ~clk;         // board mclk

    reg resetn = 0;
    initial #5000 resetn = 1;

    wire [2:0] tmds_d_p, tmds_d_n;
    wire       tmds_clk_p, tmds_clk_n;
    wire       pause_sync;
    wire [7:0] overlay_x, overlay_y;

    // behavioral SNES: line counter, OUT_Y, refresh pulse
    reg [8:0] line_no = 0;          // 0..lines-1 (PPU V_CNT-like)
    reg [10:0] line_cnt = 0;
    reg [7:0] out_y = 0;
    reg       field = 0;
    reg       snes_refresh = 0;
    reg       dotclk = 0;
    wire [8:0] lines = field ? `LINES_ODD : `LINES_EVEN;
    wire [10:0] line_len = (line_no == 240 && field &&
                            `LINES_EVEN == `LINES_ODD) ? 11'd1360 : 11'd1364;

    snes2hdmi dut (
        .clk(clk), .resetn(resetn),
        .dotclk(dotclk), .hblank(1'b1), .vblank(1'b1), .rgb5(15'd0),
        .xs(9'd0), .ys({field, out_y}), .hires(1'b0),
        .overlay(1'b0), .overlay_x(overlay_x), .overlay_y(overlay_y), .overlay_color(15'd0),
        .audio_l(16'd0), .audio_r(16'd0), .audio_ready(1'b0), .audio_en(),
        .pause(1'b0), .snes_refresh(snes_refresh),
        .scanlines(1'b0), .sl_darkness(2'd0), .sl_thick(1'b0), .sl_out(1'b0), .video_config(32'd0),
        .clk_pixel(clk_pixel), .clk_5x_pixel(1'b0), .locked(1'b1),
        .std_timing(1'b0),
        .pause_snes_for_frame_sync(pause_sync),
        .tmds_clk_n(tmds_clk_n), .tmds_clk_p(tmds_clk_p), .tmds_d_n(tmds_d_n), .tmds_d_p(tmds_d_p)
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

    integer snes_frames = 0;
    always @(posedge clk) begin
        dotclk <= ~dotclk;
        snes_refresh <= (line_cnt < 40);
        if (!pause_sync && resetn) begin
            if (line_cnt == line_len - 1) begin
                line_cnt <= 0;
                if (line_no >= 1 && line_no <= 224)
                    out_y <= out_y + 1;
                if (line_no == lines - 1) begin
                    line_no <= 0;
                    out_y <= 0;
                    field <= ~field;
                    snes_frames <= snes_frames + 1;
                end else
                    line_no <= line_no + 1;
            end else
                line_cnt <= line_cnt + 1;
        end
    end

    // measurements
    integer halt_now = 0, halt_max = 0, halt_last = 0, halts = 0;
    always @(posedge clk) begin
        if (resetn && pause_sync)
            halt_now <= halt_now + 1;
        else begin
            if (halt_now != 0) begin
                halt_last <= halt_now;
                // lock acquisition at startup may wait up to a frame;
                // only steady-state halts count towards the trap check
                if (snes_frames >= 2 && halt_now > halt_max) halt_max <= halt_now;
                halts <= halts + 1;
            end
            halt_now <= 0;
        end
    end

    reg [9:0] prev_cy = 0;
    integer frame = 0;
    integer sf0 = 0, h0 = 0;
    integer sf_base = 0, h_base = 0;
    always @(posedge clk_pixel) begin
        if (dut.cy == 0 && prev_cy == 524) begin
            frame <= frame + 1;
            if (frame == 2) begin sf_base <= snes_frames; h_base <= halts; end
            if (frame >= 2)
                $display("hdmi frame %0d: snes_frames=%0d halts=%0d halt_last=%0d halt_max=%0d mclk",
                         frame, snes_frames - sf0, halts - h0, halt_last, halt_max);
            sf0 <= snes_frames; h0 <= halts;
            if (frame == 24) begin
                // 22 HDMI frames is 11 game frames at 2x
                $display("SUMMARY locked=%0d snes_frames=%0d halts=%0d halt_max=%0d in 22 hdmi frames",
                         `LOCKED, snes_frames - sf_base, halts - h_base, halt_max);
                if (halt_max > 5000)
                    $fatal(1, "FAIL: a halt stretched to %0d mclk (missed-release trap)", halt_max);
                if (`LOCKED && (snes_frames - sf_base != 11 || halts - h_base != 11))
                    $fatal(1, "FAIL: locked config ran %0d snes frames / %0d halts in 22 hdmi frames",
                           snes_frames - sf_base, halts - h_base);
                if (!`LOCKED && snes_frames - sf_base < 10)
                    $fatal(1, "FAIL: unlocked config ran only %0d snes frames in 22 hdmi frames (stalled)",
                           snes_frames - sf_base);
                $display("PASS snes-framelock");
                $finish;
            end
        end
        prev_cy <= dut.cy;
    end

    initial begin
        #4000000000;
        $fatal(1, "tb_snes_framelock: timeout");
    end
endmodule
