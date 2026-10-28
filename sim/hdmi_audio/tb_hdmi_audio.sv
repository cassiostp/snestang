// Synthetic DSP counter stream through snes2hdmi, real HDMI packets and
// parallel TMDS. Binary output is decoded independently by decode.py.
// The frame/DSP model matches sim/snes_audio; no ROM is used.
`timescale 1ns/1ps

`ifndef MCLK_HALF_NS
`define MCLK_HALF_NS 23.2498
`endif

module tb_hdmi_audio;

    reg clk_pixel = 0, clk = 0;
`ifdef HZ120
    always #9.259 clk_pixel = ~clk_pixel;       // 54 MHz, 480p120
`else
    always #6.734 clk_pixel = ~clk_pixel;       // 74.25 MHz
`endif
    always #(`MCLK_HALF_NS) clk = ~clk;         // Console 138K mclk

    reg resetn = 0;
    initial begin
        #5000 resetn = 1;
    end

    wire [2:0] tmds_d_p, tmds_d_n;
    wire       tmds_clk_p, tmds_clk_n;
    wire       pause_sync;
    wire [7:0] overlay_x, overlay_y;

    // ACLK_FREQ from src/dsp.vh, over the CEGen IN_CLK (board-independent: rates are exact counter ratios)
`ifdef LEGACY
    parameter PROD_NUM = 411904;
`else
    parameter PROD_NUM = 409584;
`endif
    parameter PROD_DEN = 2147730;

    reg [15:0] audio_l = 0, audio_r = 0;
    reg        audio_ready = 0;
    reg [31:0] prod_acc = 0;
    reg [15:0] prod_cnt = 0;

    // behavioral SNES frame: 262 lines of 1364 mclk (1360 at line 240 of
    // odd frames), refresh pulse each line
    reg [8:0] ys = 0;
    reg [10:0] line_cnt = 0;
    reg        field = 0;
    reg        snes_refresh = 0;
    reg        dotclk = 0;
    wire [10:0] line_len = (ys == 240 && field) ? 11'd1360 : 11'd1364;

    snes2hdmi dut (
        .clk(clk), .resetn(resetn),
        .dotclk(dotclk), .hblank(1'b1), .vblank(1'b1), .rgb5(15'd0), .xs(9'd0), .ys(ys), .hires(1'b0),
        .overlay(1'b0), .overlay_x(overlay_x), .overlay_y(overlay_y), .overlay_color(15'd0),
        .audio_l(audio_l), .audio_r(audio_r), .audio_ready(audio_ready), .audio_en(),
        .pause(1'b0), .snes_refresh(snes_refresh),
        .scanlines(1'b0), .sl_darkness(2'd0), .sl_thick(1'b0), .sl_out(1'b0), .video_config(32'd0),
        .clk_pixel(clk_pixel), .clk_5x_pixel(1'b0), .locked(1'b1),
`ifndef LEGACY
        .std_timing(1'b0),
`endif
        .pause_snes_for_frame_sync(pause_sync),
        .tmds_clk_n(tmds_clk_n), .tmds_clk_p(tmds_clk_p), .tmds_d_n(tmds_d_n), .tmds_d_p(tmds_d_p)
    );

    // the frame-sync regs have no reset (the FPGA powers them up 0): deposit
    // power-up state at time 0 or the first sync never engages
    initial begin
        dut.audio_divider = 0;
        dut.clk_audio = 0;
        dut.audio_rinc = 0;
        dut.pause_snes_for_frame_sync = 0;
        dut.sync_done = 0;
`ifndef LEGACY
        dut.fl_missed = 0;
`endif
        dut.pause_sync = 0;
        dut.hdmi_first_line = 0;
        dut.hdmi_first_line_r = 0;
        dut.hdmi_first_line_rr = 0;
    end


    // SNES model + DSP production, frozen while the frame sync holds the SNES
    always @(posedge clk) begin
        audio_ready <= 1'b0;
        dotclk <= ~dotclk;
        // WRAM refresh: a short pulse every scanline (as in cpu.v); the frame
        // sync halts on ys == 1 && snes_refresh
        snes_refresh <= (line_cnt < 40);
        if (!pause_sync && resetn) begin
            if (line_cnt == line_len - 1) begin
                line_cnt <= 0;
                if (ys == 261) begin
                    ys <= 0;
                    field <= ~field;
                end else
                    ys <= ys + 1;
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

    integer frame = 0;
    reg [9:0] prev_cy = 0;
    integer fd;
    string output_path;
    initial begin
        if (!$value$plusargs("stream=%s", output_path)) output_path = "stream.bin";
        fd = $fopen(output_path, "wb");
        if (!fd) $fatal(1, "cannot open TMDS output");
    end
    always @(negedge clk_pixel) begin
        if (resetn) begin
            $fwrite(fd, "%u", {2'b0, dut.hdmi.tmds_internal[2], dut.hdmi.tmds_internal[1], dut.hdmi.tmds_internal[0]});
`ifdef HZ120
            if (dut.cy == 0 && prev_cy == 524) begin
`else
            if (dut.cy == 0 && prev_cy == 749) begin
`endif
                frame = frame + 1;
                if (frame == 8) begin
                    $fclose(fd);
                    $display("TMDS stream: frames=%0d produced=%0d", frame, prod_cnt);
                    $finish;
                end
            end
            prev_cy = dut.cy;
        end
    end
endmodule

module ELVDS_OBUF(input I, output O, output OB);
    assign O = I;
    assign OB = ~I;
endmodule
