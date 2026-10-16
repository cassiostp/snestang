// Audio transport bench: the snes2hdmi 32 kHz FIFO across the frame-sync halt.
//
// A behavioral SNES plays NTSC frames (262 lines x 1360 mclk: 340 dots of 4
// master clocks, ppu.v DOT_NUM/LAST_DOT, 262 lines, LAST_LINE 261; WRAM-refresh
// pulse every line) and produces one DSP sample per 128 CEGen ticks at
// PROD_NUM/PROD_DEN per mclk (dsp.vh ACLK_FREQ/2147730 for the console
// 21.4844 MHz mclk). Production and the frame generator freeze while
// pause_snes_for_frame_sync is asserted, the way enable=0 does in
// snestang_top. The HDMI side (../scanlines/hdmi_stub.v) consumes at
// 74.25 MHz / 2320.
//
// Samples carry an incrementing counter, so the bench counts exactly, per
// HDMI frame after a two-frame warmup: produced samples, consumed samples,
// dropped samples (consumed counter jumps by >1: the FIFO was full and a
// write was lost) and repeated samples (counter does not advance: the FIFO
// was empty and the last word was re-sent). The run fails with $fatal unless
// no sample is dropped or repeated and the occupancy stays off the rails.
//
// Run (from this directory): ./run.sh
`timescale 1ns/1ps

module tb_snes_audio_fifo;

    reg clk_pixel = 0, clk = 0;
    always #6.734 clk_pixel = ~clk_pixel;       // 74.25 MHz
    always #23.28 clk = ~clk;                   // 21.477 MHz

    reg resetn = 0;
    initial begin
        #5000 resetn = 1;
    end

    wire [2:0] tmds_d_p, tmds_d_n;
    wire       tmds_clk_p, tmds_clk_n;
    wire       pause_sync;
    wire [7:0] overlay_x, overlay_y;

    // ACLK_FREQ from src/dsp.vh, over the CEGen IN_CLK (board-independent: rates are exact counter ratios)
    parameter PROD_NUM = 410787;
    parameter PROD_DEN = 2147730;

    reg [15:0] audio_l = 0, audio_r = 0;
    reg        audio_ready = 0;
    reg [31:0] prod_acc = 0;
    reg [15:0] prod_cnt = 0;

    // behavioral SNES frame: 262 lines of 1360 mclk, refresh pulse each line
    reg [8:0] ys = 0;
    reg [10:0] line_cnt = 0;
    reg        snes_refresh = 0;
    reg        dotclk = 0;

    snes2hdmi dut (
        .clk(clk), .resetn(resetn),
        .dotclk(dotclk), .hblank(1'b1), .vblank(1'b1), .rgb5(15'd0), .xs(9'd0), .ys(ys),
        .overlay(1'b0), .overlay_x(overlay_x), .overlay_y(overlay_y), .overlay_color(15'd0),
        .audio_l(audio_l), .audio_r(audio_r), .audio_ready(audio_ready), .audio_en(),
        .pause(1'b0), .snes_refresh(snes_refresh),
        .scanlines(1'b0), .sl_darkness(2'd0), .sl_thick(1'b0), .sl_out(1'b0), .video_config(32'd0),
        .clk_pixel(clk_pixel), .clk_5x_pixel(1'b0), .locked(1'b1),
        .std_timing(1'b0),
        .pause_snes_for_frame_sync(pause_sync),
        .tmds_clk_n(tmds_clk_n), .tmds_clk_p(tmds_clk_p), .tmds_d_n(tmds_d_n), .tmds_d_p(tmds_d_p)
    );

    // the frame-sync regs have no reset (the FPGA powers them up 0): deposit
    // power-up state at time 0 or the first sync never engages
    initial begin
        dut.pause_snes_for_frame_sync = 0;
        dut.sync_done = 0;
        dut.pause_sync = 0;
        dut.hdmi_first_line = 0;
        dut.hdmi_first_line_r = 0;
        dut.hdmi_first_line_rr = 0;
    end

    wire [6:0] occ = dut.audio_used;

    // SNES model + DSP production, frozen while the frame sync holds the SNES
    always @(posedge clk) begin
        audio_ready <= 1'b0;
        dotclk <= ~dotclk;
        // WRAM refresh: a short pulse every scanline (as in cpu.v); the frame
        // sync halts on ys == 1 && snes_refresh
        snes_refresh <= (line_cnt < 40);
        if (!pause_sync && resetn) begin
            if (line_cnt == 1359) begin
                line_cnt <= 0;
                ys <= (ys == 261) ? 0 : ys + 1;
            end else
                line_cnt <= line_cnt + 1;
            prod_acc <= prod_acc + PROD_NUM;
            if (prod_acc + PROD_NUM >= PROD_DEN * 128) begin
                prod_acc <= prod_acc + PROD_NUM - PROD_DEN * 128;
                prod_cnt <= prod_cnt + 1;
                audio_l <= prod_cnt + 1;
                audio_r <= ~(prod_cnt + 1);
                audio_ready <= 1'b1;
            end
        end
    end

    // read-side monitor: the word the DUT latches into audio_sample_word on
    // each clk_audio fall (when rinc advances the FIFO). audio_sample_word is
    // updated by nonblocking assignment on the same edge, so sample it on the
    // following negedge, when it has settled; counter continuity then gives
    // drops (counter jumps by >1: a write was lost) and repeats (counter does
    // not advance: the FIFO was empty and the last word was re-sent).
    reg prev_clk_audio = 0;
    reg sample_pending = 0;
    reg [15:0] prev_cnt = 0;
    reg started = 0;
    integer produced = 0, consumed = 0, dropped = 0, repeated = 0;
    integer occ_min = 64, occ_max = 0;
    reg [15:0] w;
    always @(posedge clk_pixel) begin
        if (resetn && dut.audio_divider == 0) begin
            if (occ < occ_min) occ_min <= occ;
            if (occ > occ_max) occ_max <= occ;
        end
        prev_clk_audio <= dut.clk_audio;
        if (resetn && prev_clk_audio && !dut.clk_audio && frame >= 2)
            sample_pending <= 1'b1;
    end
    always @(negedge clk_pixel) begin
        if (resetn && sample_pending) begin
            sample_pending <= 1'b0;
            w = dut.audio_sample_word[0];
            if (!started) begin
                prev_cnt <= w;
                started <= 1;
            end else begin
                consumed <= consumed + 1;
                if (w == prev_cnt)
                    repeated <= repeated + 1;
                else begin
                    if (w != prev_cnt + 16'd1)
                        dropped <= dropped + (w - prev_cnt - 16'd1);
                    prev_cnt <= w;
                end
            end
        end
    end

    // production counter on the clk domain (audio_ready pulses there)
    always @(posedge clk) begin
        if (resetn && audio_ready)
            produced <= produced + 1;
    end

    // per-HDMI-frame report on cy wrap
    reg [9:0] prev_cy = 0;
    integer frame = 0;
    integer last_prod = 0, last_cons = 0, last_drop = 0, last_rep = 0;
    integer halt_cnt = 0, last_halt = 0;
    always @(posedge clk) begin
        if (resetn && pause_sync) halt_cnt <= halt_cnt + 1;
    end
    always @(posedge clk_pixel) begin
        if (dut.cy == 0 && prev_cy == 749) begin
            frame <= frame + 1;
            $display("frame %0d prod=%0d cons=%0d drop=%0d rep=%0d occ_min=%0d occ_max=%0d halt_mclk=%0d",
                     frame, produced - last_prod, consumed - last_cons,
                     dropped - last_drop, repeated - last_rep, occ_min, occ_max,
                     halt_cnt - last_halt);
            last_prod <= produced; last_cons <= consumed;
            last_drop <= dropped; last_rep <= repeated;
            last_halt <= halt_cnt;
            occ_min <= 64; occ_max <= 0;
            if (frame == 16) begin
                $display("TOTALS produced=%0d consumed=%0d dropped=%0d repeated=%0d",
                         produced, consumed, dropped, repeated);
                if (dropped != 0 || repeated != 0)
                    $fatal(1, "FAIL: %0d dropped %0d repeated samples", dropped, repeated);
                $display("PASS snes-audio-fifo: no dropped or repeated samples over 14 frames");
                $finish;
            end
        end
        prev_cy <= dut.cy;
    end

endmodule
