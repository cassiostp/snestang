// The line buffer as the SNES fills it: the question is whether the line a row shows
// has been written when it is read, and not yet overwritten by the line 32 lines later.
// The SNES is played by a model of the PPU's video output (340 dots a line, dots 323 and 327
// of 6 master clocks and the rest of 4, a 1360-clock short line at line 240 of odd frames,
// 262 lines, pixel x of a line is written to the buffer OFS dots after the line starts, nothing
// in the blanking, the line counter ys as ppu.v counts it) and of the refresh that
// snes2hdmi's frame sync waits for (once a line, from dot 133 on, 40 master clocks), halted by
// pause_snes_for_frame_sync like snestang_top does; the real snes2hdmi runs the frame sync.
//
// Every write to the buffer is tagged with the frame and the line it belongs to (a pixel
// written before the line's own pixels, or on line 0 of the 262, is tagged as junk). Every read
// whose result the picture can depend on - the shown line - must find the tag of the frame
// and line it wants: the pixel has been written, and not yet overwritten by line + 32. Checked
// at every address cycle of the picture, with the default and the integer scale geometry, with
// scanlines in output rows mode. STALL slows the SNES down; the frame sync
// only works while the SNES frame (262 lines) is shorter than the picture's, which it is by
// 405 master clocks on console138k and 56 on console60k, so even a small STALL breaks the lock.
// Also reported: the shortest time between the last read of a pixel and its being overwritten,
// and the largest lead of the SNES over the picture (the buffer holds 32 lines, so 31 is the limit).
`timescale 1ns/1ps

`ifndef MCLK_HALF_NS
`define MCLK_HALF_NS 23.2727
`endif

module tb_snes_linebuf #(
    parameter OFS = 18,         // dots from the start of a line to its first pixel (18 is the latest, the blanking starts at 274)
    parameter STALL = 0         // 0, or the SNES loses one dot in STALL (a stall of the enable costs whole dots)
);

    reg clk_pixel = 0, clk = 0;
    always #6.734 clk_pixel = ~clk_pixel;       // 74.25 MHz
    always #(`MCLK_HALF_NS) clk = ~clk;         // board mclk (run.sh: 138K and 60K)

    reg        sl_on = 0, sl_thick = 0, sl_out = 0;
    reg  [1:0] sl_dark = 0;
    reg [31:0] vcfg = 0;

    wire [7:0] ovx, ovy;
    wire [2:0] tmds_d_p, tmds_d_n;
    wire       tmds_clk_p, tmds_clk_n;
    wire       pause_sync;

    // ---- the PPU's video output
    reg [2:0]  c = 0;           // master clock within the dot
    reg [8:0]  h = 0, v = 0;    // dot, line
    reg        field = 0;
    wire [2:0] dotlen = ((h == 9'd323 || h == 9'd327) && !(v == 9'd240 && field)) ? 3'd6 : 3'd4;
    reg [11:0] wframe = 0;
    reg        en = 0;
    integer    scnt = 0;
    reg        dotclk = 0, hblank = 0, vblank = 0;
    reg [8:0]  xs = 0, ys = 0;
    reg [14:0] rgb5 = 0;
    reg        junk = 1;        // the pixel being output is not final
    reg        refresh = 0;
    reg [1:0]  rst = 0;
    reg [5:0]  rcnt = 0;

    function [8:0] x_of(input [8:0] hh);
        x_of = (hh < OFS) ? 9'd255 : (hh - OFS < 256) ? hh - OFS : 9'd255;
    endfunction
    function [8:0] ys_of(input [8:0] vv);
        ys_of = (vv <= 1) ? 9'd0 : (vv - 1 > 224) ? 9'd224 : vv - 1;
    endfunction

    reg [8:0] nh, nv;
    always @(posedge clk) begin
        en <= ~pause_sync;
        c <= (c == dotlen - 3'd1) ? 3'd0 : c + 3'd1;
        dotclk <= (c == dotlen - 3'd1) || (c == 3'd0);
        if (en && c == dotlen - 3'd1 && STALL != 0 && scnt == STALL - 1)
            scnt <= 0;                  // this dot is lost
        else if (en && c == dotlen - 3'd1) begin
            scnt <= scnt + 1;
            nh = (h == 9'd339) ? 9'd0 : h + 9'd1;
            nv = (h == 9'd339) ? ((v == 9'd261) ? 9'd0 : v + 9'd1) : v;
            h <= nh; v <= nv;
            if (h == 9'd339 && v == 9'd261) begin wframe <= wframe + 12'd1; field <= ~field; end
            hblank <= (nh >= 274);
            vblank <= (nv >= 225);
            ys <= ys_of(nv);
            xs <= {x_of(nh), 1'b1};
            junk <= (nh < OFS) || (nv == 0);
            rgb5 <= {nh[4:0], nv[4:0], nh[7:3] ^ nv[7:3]};
        end
        // the refresh, once a line from dot 133 on
        case (rst)
        2'd0: if (en && h >= 133) begin refresh <= 1; rst <= 2'd1; rcnt <= 0; end
        2'd1: if (en) begin
                  rcnt <= rcnt + 6'd1;
                  if (rcnt == 6'd39) begin refresh <= 0; rst <= 2'd2; end
              end
        default: if (h < 133) rst <= 2'd0;
        endcase
    end

    reg [14:0] ovc = 15'd0;

    snes2hdmi dut (
        .clk(clk), .resetn(1'b1),
        .dotclk(dotclk), .hblank(hblank), .vblank(vblank), .rgb5(rgb5), .xs(xs), .ys(ys),
        .hires(1'b0),
        .overlay(1'b0), .overlay_x(ovx), .overlay_y(ovy), .overlay_color(ovc),
        .audio_l(16'd0), .audio_r(16'd0), .audio_ready(1'b0), .audio_en(), .pause(1'b0),
        .snes_refresh(refresh),
        .scanlines(sl_on), .sl_darkness(sl_dark), .sl_thick(sl_thick), .sl_out(sl_out),
        .video_config(vcfg),
        .clk_pixel(clk_pixel), .clk_5x_pixel(1'b0), .locked(1'b1),
        .std_timing(1'b0),
        .pause_snes_for_frame_sync(pause_sync),
        .tmds_clk_n(tmds_clk_n), .tmds_clk_p(tmds_clk_p), .tmds_d_n(tmds_d_n), .tmds_d_p(tmds_d_p)
    );

    initial dut.pause_snes_for_frame_sync = 1'b0;    // no reset value in the scaler (the FPGA starts it at 0)

    // ---- what the buffer holds: {frame, line} of every pixel, all ones for junk
    localparam [19:0] JUNK = 20'hFFFFF;
    reg  [19:0] tag [0:32 * 256 - 1];
    real        wt  [0:32 * 256 - 1];       // when the pixel got its tag
    real        lr  [0:32 * 256 - 1];       // when the pixel was last read (0: not since it got its tag)
    reg  [19:0] pend;
    integer     ii;
    initial for (ii = 0; ii < 32 * 256; ii = ii + 1) begin tag[ii] = JUNK; wt[ii] = 0.0; lr[ii] = 0.0; end

    real ow_min = 1.0e9;                    // read -> overwrite
    always @(posedge clk) begin
        pend <= junk ? JUNK : {wframe, ys[7:0]};       // what the scaler samples on this edge
        if (dut.mem_portA_we && tag[dut.mem_portA_addr] !== pend) begin
            if (lr[dut.mem_portA_addr] > 0.0 && $realtime - lr[dut.mem_portA_addr] < ow_min)
                ow_min = $realtime - lr[dut.mem_portA_addr];
            tag[dut.mem_portA_addr] = pend;
            wt[dut.mem_portA_addr]  = $realtime;
            lr[dut.mem_portA_addr]  = 0.0;
        end
    end

    // the frame the picture shows: the one the SNES is in when the frame sync releases it. The
    // scaler reads the first row from before the release (the SNES has been waiting for it, in
    // the frame the picture is about to show).
    reg [11:0] rframe = 0;
    integer    releases = 0;
    always @(negedge pause_sync) begin
        rframe = wframe;
        releases = releases + 1;
    end

    // ---- every read the picture can depend on finds its pixel
    reg     armed = 0;
    integer checks = 0, bad = 0, lead_max = 0, lead;
    real    age;
    reg [7:0] expl;
    reg [12:0] raddr;
    reg [11:0] eframe;
    always @(posedge clk_pixel) begin
        if (armed && dut.active && dut.sl_show && dut.cy < 10'd720) begin
            raddr = dut.mem_portB_addr;
            expl  = dut.yy_s;
            eframe = (pause_sync && dut.cy == dut.sl_pic_top) ? wframe : rframe;
            checks = checks + 1;
            if (tag[raddr] !== {eframe, expl}) begin
                bad = bad + 1;
                if (bad <= 10)
                    $display("MISSING: row %0d shows line %0d, read column %0d: buffer has frame/line %0d/%0d (frame %0d, SNES at line %0d dot %0d)",
                             dut.cy, dut.yy_s, raddr[7:0],
                             tag[raddr][19:8], tag[raddr][7:0], eframe, v, h);
            end else begin
                age = $realtime - wt[raddr];
                lr[raddr] = $realtime;
            end
            lead = (v >= 1 && v <= 224) ? (v - 1) - expl : 0;
            if (lead > lead_max) lead_max = lead;
        end
    end

    // ---- the settings
    task run(input on, input out, input thick, input [1:0] dk, input [31:0] cfg);
        integer r0;
        begin
            sl_on = on; sl_out = out; sl_thick = thick; sl_dark = dk; vcfg = cfg;
            armed = 0;
            r0 = releases;
            while (releases < r0 + 2) @(posedge clk_pixel);     // a whole frame with these settings first
            checks = 0; bad = 0; ow_min = 1.0e9; lead_max = 0;
            armed = 1;
            r0 = releases;
            while (releases < r0 + 3) @(posedge clk_pixel);     // then two whole frames
            armed = 0;
            $display("scanlines=%b out=%b thick=%b video_config=%h: %0d reads checked, %0d missing; pixel read >= %0.1f us before it is overwritten, SNES ahead by <= %0d lines",
                     on, out, thick, cfg, checks, bad, ow_min / 1000.0, lead_max);
            if (bad != 0 || checks < 100000) begin
                $display("tb_snes_linebuf: FAIL");
                $fatal(1, "tb_snes_linebuf: FAIL");
            end
        end
    endtask

    initial begin
        $display("tb_snes_linebuf: OFS=%0d STALL=%0d", OFS, STALL);
        //  on out thk dk  video_config
        run(0, 0, 0, 2, 32'h0);                // scanlines off, integer scale
        run(0, 1, 0, 2, 32'h0);                // scanlines off, full scale
        run(1, 0, 0, 2, 32'h0);                // integer scale, 896x672
        run(1, 0, 1, 2, 32'h0);                // integer scale, thick
        run(1, 1, 0, 2, 32'h0);                // output rows, 960x720
        $display("tb_snes_linebuf: PASS");
        $finish;
    end

    initial begin
        #2000000000000;
        $fatal(1, "tb_snes_linebuf: timeout");
    end
endmodule
