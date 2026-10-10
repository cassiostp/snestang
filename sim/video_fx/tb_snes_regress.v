// snes2hdmi with video_fx against the scaler before video_fx (the baseline, built from the git
// history by prep.sh as snes2hdmi_base): a video_config that enables nothing must give the very
// same rgb stream into the hdmi module, clock for clock, in every scanline mode, with the menu
// overlay up or not. The words tried: 0, what the firmware sends with every filter off (the
// strengths at 1), and one with the LCD grid bit set, which the SNES ignores.
// The SNES is played by the testbench: the source line a row shows is written into the 32-line
// buffer, with pseudo-random pixels that depend on the line (not only on its slot, the line
// number modulo 32), before the row starts, so a row that reads another line, or a column
// that is off by one, is caught. The overlay is a pattern read through the overlay_x /
// overlay_y outputs with a three clock latency, like textdisp. Settings change in the
// blanking, then two whole frames are compared. The frame sync outputs (the SNES release and
// hdmi_first_line) must be the same too.
`timescale 1ns/1ps

module tb_snes_regress;

    reg clk_pixel = 0, clk = 0;
    always #6.734 clk_pixel = ~clk_pixel;       // 74.25 MHz
    always #23.28 clk = ~clk;                   // 21.477 MHz

    reg        sl_on = 0, sl_thick = 0, sl_out = 0, ov = 0;
    reg  [1:0] sl_dark = 0;
    reg [31:0] vcfg = 0;

    wire [7:0] ovx_n, ovy_n, ovx_b, ovy_b;
    reg [14:0] ovc_n, ovc_b, ovc_n1, ovc_b1, ovc_n2, ovc_b2;
    function [14:0] ov_pix(input [7:0] x, input [7:0] y);
        ov_pix = {x[4:0] ^ y[6:2], x[7:3] + y[4:0], y[7:3] ^ x[6:2]};
    endfunction
    always @(posedge clk_pixel) begin
        ovc_n2 <= ov_pix(ovx_n, ovy_n); ovc_n1 <= ovc_n2; ovc_n <= ovc_n1;
        ovc_b2 <= ov_pix(ovx_b, ovy_b); ovc_b1 <= ovc_b2; ovc_b <= ovc_b1;
    end

    wire [2:0] tmds_d_p, tmds_d_n, tmds_d_pb, tmds_d_nb;
    wire       tmds_clk_p, tmds_clk_n, tmds_clk_pb, tmds_clk_nb;
    wire       pause_n, pause_b;

    snes2hdmi dut (
        .clk(clk), .resetn(1'b1),
        .dotclk(1'b0), .hblank(1'b1), .vblank(1'b1), .rgb5(15'd0), .xs(9'd0), .ys(9'd0),
        .overlay(ov), .overlay_x(ovx_n), .overlay_y(ovy_n), .overlay_color(ovc_n),
        .audio_l(16'd0), .audio_r(16'd0), .audio_ready(1'b0), .audio_en(), .pause(1'b0),
        .snes_refresh(1'b0),
        .scanlines(sl_on), .sl_darkness(sl_dark), .sl_thick(sl_thick), .sl_out(sl_out),
        .video_config(vcfg),
        .clk_pixel(clk_pixel), .clk_5x_pixel(1'b0), .locked(1'b1),
        .pause_snes_for_frame_sync(pause_n),
        .tmds_clk_n(tmds_clk_n), .tmds_clk_p(tmds_clk_p), .tmds_d_n(tmds_d_n), .tmds_d_p(tmds_d_p)
    );

    snes2hdmi_base base (
        .clk(clk), .resetn(1'b1),
        .dotclk(1'b0), .hblank(1'b1), .vblank(1'b1), .rgb5(15'd0), .xs(9'd0), .ys(9'd0),
        .overlay(ov), .overlay_x(ovx_b), .overlay_y(ovy_b), .overlay_color(ovc_b),
        .audio_l(16'd0), .audio_r(16'd0), .audio_ready(1'b0), .audio_en(), .pause(1'b0),
        .snes_refresh(1'b0),
        .scanlines(sl_on), .sl_darkness(sl_dark), .sl_thick(sl_thick), .sl_out(sl_out),
        .clk_pixel(clk_pixel), .clk_5x_pixel(1'b0), .locked(1'b1),
        .pause_snes_for_frame_sync(pause_b),
        .tmds_clk_n(tmds_clk_nb), .tmds_clk_p(tmds_clk_pb), .tmds_d_n(tmds_d_nb), .tmds_d_p(tmds_d_pb)
    );

    // source line l, column c
    function [14:0] pix(input [7:0] l, input [7:0] c);
        reg [31:0] h;
        begin
            h = {16'd0, l, c} * 32'd2654435761;
            h = h ^ (h >> 15);
            h = h * 32'd2246822519;
            pix = h[29:15];
        end
    endfunction

    // the line buffer: every slot holds something before the first row, and the line a row
    // shows is written in full before its pixels are read (the row starts at cx = 0, the
    // scaler reads from cx = 149 on)
    integer i, fc;
    reg [7:0] fl;
    initial begin
        #1;
        for (i = 0; i < 32 * 256; i = i + 1) begin
            dut.mem[i]  = pix(i[12:8], i[7:0]);
            base.mem[i] = pix(i[12:8], i[7:0]);
        end
    end
    always @(posedge clk_pixel) begin
        if (dut.cx == 11'd100) begin
            fl = base.yy_s;
            for (fc = 0; fc < 256; fc = fc + 1) begin
                dut.mem[{fl[4:0], fc[7:0]}]  = pix(fl, fc[7:0]);
                base.mem[{fl[4:0], fc[7:0]}] = pix(fl, fc[7:0]);
            end
        end
    end

    // compare the rgb inputs of the two hdmi modules on every visible row
    reg     armed = 0;
    integer cmp = 0, bad = 0, picture = 0, total_cmp = 0, total_pic = 0, bad_sync = 0;
    always @(negedge clk_pixel) begin
        if (armed) begin
            if (pause_n !== pause_b || dut.hdmi_first_line !== base.hdmi_first_line) begin
                bad_sync = bad_sync + 1;
                if (bad_sync <= 8)
                    $display("SYNC MISMATCH cy=%0d cx=%0d: pause %b/%b first_line %b/%b", dut.cy, dut.cx,
                             pause_n, pause_b, dut.hdmi_first_line, base.hdmi_first_line);
            end
        end
        if (armed && dut.cy < 10'd720) begin
            cmp = cmp + 1;
            if (dut.rgb !== 24'h303030) picture = picture + 1;
            if (dut.rgb !== base.rgb || dut.cx !== base.cx || dut.cy !== base.cy) begin
                bad = bad + 1;
                if (bad <= 8)
                    $display("MISMATCH cy=%0d cx=%0d: got %h, baseline %h", dut.cy, dut.cx, dut.rgb, base.rgb);
            end
        end
    end

    // the row where the settings change: blanking, no picture in flight
    task wait_row730;
        begin
            while (dut.cy == 10'd730) @(posedge clk_pixel);
            while (dut.cy != 10'd730) @(posedge clk_pixel);
        end
    endtask

    task variant(input on, input out, input thick, input [1:0] dk, input over, input [31:0] cfg);
        begin
            sl_on = on; sl_out = out; sl_thick = thick; sl_dark = dk; ov = over; vcfg = cfg;
            cmp = 0; bad = 0; picture = 0; bad_sync = 0;
            armed = 1;                          // rows 730.. of this frame are not compared
            wait_row730;                        // the first frame with these settings
            wait_row730;                        // the second
            if (bad != 0 || bad_sync != 0) begin
                $display("FAIL: on=%b out=%b thick=%b dark=%0d overlay=%b video_config=%h: %0d of %0d pixels differ, %0d sync differences",
                         on, out, thick, dk, over, cfg, bad, cmp, bad_sync);
                $fatal(1, "tb_snes_regress: FAIL");
            end
            if (cmp < 2 * 720 * 1650 - 10 || (!over && picture < 2 * 500 * 800)) begin
                $display("FAIL: only %0d pixels compared, %0d of them picture", cmp, picture);
                $fatal(1, "tb_snes_regress: FAIL");
            end
            total_cmp = total_cmp + cmp; total_pic = total_pic + picture;
            $display("snes2hdmi on=%b out=%b thick=%b darkness=%0d overlay=%b video_config=%h: %0d pixels identical (%0d picture)",
                     on, out, thick, dk, over, cfg, cmp, picture);
            armed = 0;
        end
    endtask

    localparam [31:0] OFF = 32'h0000_0000, FW_OFF = 32'h0001_2000, GRID = 32'h0003_A000;

    initial begin
        // the sync registers have no reset value in the scaler (the FPGA starts them at 0)
        dut.pause_snes_for_frame_sync = 1'b0;
        base.pause_snes_for_frame_sync = 1'b0;
        // the first frame runs the pipelines empty; the settings are applied in its blanking
        wait_row730;
        variant(0, 0, 0, 2, 0, OFF);
        variant(0, 0, 0, 2, 0, FW_OFF);
        variant(0, 0, 0, 2, 0, GRID);
        variant(1, 0, 0, 2, 0, OFF);            // integer scale, thin
        variant(1, 0, 0, 2, 0, FW_OFF);
        variant(1, 0, 1, 0, 0, FW_OFF);         // thick, 25 %
        variant(1, 0, 1, 3, 0, OFF);            // 100 %
        variant(1, 0, 0, 1, 0, GRID);
        variant(1, 1, 0, 2, 0, OFF);            // output rows
        variant(1, 1, 1, 1, 0, FW_OFF);
        variant(0, 0, 0, 2, 1, OFF);            // menu overlay up
        variant(0, 0, 0, 2, 1, FW_OFF);
        variant(1, 0, 0, 2, 1, FW_OFF);
        variant(1, 1, 1, 2, 1, OFF);
        variant(1, 0, 1, 2, 0, FW_OFF);         // and back
        $display("tb_snes_regress: %0d pixels identical to the baseline (%0d picture)", total_cmp, total_pic);
        $display("tb_snes_regress: PASS");
        $finish;
    end

    initial begin
        #4000000000000;
        $fatal(1, "tb_snes_regress: timeout");
    end
endmodule
