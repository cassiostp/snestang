// PPU scanline/frame timing against real NTSC hardware.
//
// Real NTSC SNES (fullsnes "SNES Timing H/V Counters", ares
// sfc/ppu/counter/inline.hpp, SNES_MiSTer rtl/PPU.vhd clock gen):
//   line = 1364 master clocks, 340 dots; dots 323 and 327 are 6 clocks,
//   the rest 4. Short line: NTSC, interlace off, field=1, line 240 runs
//   1360 clocks (all dots 4). Frames: 262 lines -> 357368 clocks on the
//   even field, 357364 on the odd field (357366 average, 60.0988 Hz).
//   Interlaced: fields of 263/262 lines, no short line.
// This bench counts CLK cycles per dot, per line and per field from the
// real SPPU and fails unless they match. Register state (BGINTERLACE)
// is poked directly, as in sim/ppu_sprite; VRAM reads return FF.
`timescale 1ns/1ps

module tb_ppu_timing;
    logic clk = 0;
    always #1 clk = ~clk;

    logic rst_n = 0;
    logic dis_shortline = 0;
    logic pal = 0;
    wire [15:0] vram_addra, vram_addrb;
    wire [7:0] vram_dao, vram_dbo;
    wire [7:0] ppu_do;
    wire [14:0] color_out;
    wire [8:0] x_out, y_out;
    wire field_out, hblank, vblank;

    SPPU dut (
        .RST_N(rst_n), .CLK(clk), .ENABLE(1'b1), .DIS_SHORTLINE(dis_shortline),
        .PA(8'b0), .PARD_N(1'b1), .PAWR_N(1'b1), .DI(8'b0), .DO(ppu_do),
        .SYSCLK_CE(1'b0),
        .VRAM_ADDRA(vram_addra), .VRAM_ADDRB(vram_addrb),
        .VRAM_DAI(8'hFF), .VRAM_DBI(8'hFF),
        .VRAM_DAO(vram_dao), .VRAM_DBO(vram_dbo),
        .VRAM_WRA_N(), .VRAM_WRB_N(), .VRAM_RD_N(),
        .EXTLATCH(1'b0), .PAL(pal), .BLEND(1'b0),
        .HIGH_RES(), .DOTCLK(), .HBLANK(hblank), .VBLANK(vblank),
        .COLOR_OUT(color_out), .X_OUT(x_out), .Y_OUT(y_out),
        .HDE(), .VDE(), .V224(), .FIELD_OUT(field_out), .INTERLACE(),
        .HSYNC(), .VSYNC(), .FRAME_OUT(), .BG_EN(5'b11111)
    );

    longint cyc = 0;
    always @(posedge clk) cyc <= cyc + 1;

    // ---- measurement state, sampled on negedge (all NBAs settled)
    integer errors = 0;
    longint last_hchg = 0, last_vchg = 0, last_field = 0;
    reg [8:0] prev_h = 0, prev_v = 0;
    reg prev_field = 0;
    integer dot_clocks [0:341];      // last measured clocks for each dot
    integer line_clocks [0:511];     // last measured clocks for each V_CNT line
    integer frame_clocks [0:15];     // last 16 field lengths
    integer frame_lines  [0:15];     // lines in each of those fields
    integer nframes = 0;
    integer lines_this_frame = 0;
    integer frame_field [0:15];      // FIELD value during each measured field
    reg measuring = 0;

    always @(negedge clk) begin
        if (rst_n && measuring) begin
            if (dut.H_CNT !== prev_h) begin
                if (prev_h <= 341) dot_clocks[prev_h] = cyc - last_hchg;
                last_hchg = cyc;
                prev_h = dut.H_CNT;
            end
            if (dut.V_CNT !== prev_v) begin
                if (prev_v <= 511) line_clocks[prev_v] = cyc - last_vchg;
                last_vchg = cyc;
                lines_this_frame++;
                prev_v = dut.V_CNT;
            end
            if (field_out !== prev_field) begin
                if (nframes < 16) begin
                    frame_clocks[nframes] = cyc - last_field;
                    frame_lines[nframes] = lines_this_frame;
                    frame_field[nframes] = prev_field;
                end
                nframes++;
                lines_this_frame = 0;
                last_field = cyc;
                prev_field = field_out;
            end
        end
    end

    task reset_meas();
        begin
            @(negedge clk);
            measuring = 0;
            nframes = 0; lines_this_frame = 0;
            prev_h = dut.H_CNT; prev_v = dut.V_CNT; prev_field = field_out;
            last_hchg = cyc; last_vchg = cyc; last_field = cyc;
            for (int i = 0; i < 342; i++) dot_clocks[i] = 0;
            for (int i = 0; i < 512; i++) line_clocks[i] = 0;
            measuring = 1;
        end
    endtask

    task wait_frames(input integer n);
        integer target;
        begin
            target = nframes + n;
            while (nframes < target) @(negedge clk);
        end
    endtask

    task check(input bit cond, input string what, input integer got, input integer want);
        begin
            if (!cond) begin
                errors++;
                $display("FAIL: %s got=%0d want=%0d", what, got, want);
            end
        end
    endtask

    task report_frames(input string tag, input integer n);
        begin
            for (int i = 0; i < n && i < 16; i++)
                $display("%s frame %0d: field=%0d lines=%0d clocks=%0d",
                         tag, i, frame_field[i], frame_lines[i], frame_clocks[i]);
            $display("%s dots: 0=%0d 100=%0d 322=%0d 323=%0d 324=%0d 326=%0d 327=%0d 328=%0d 339=%0d (clocks)",
                     tag, dot_clocks[0], dot_clocks[100], dot_clocks[322],
                     dot_clocks[323], dot_clocks[324], dot_clocks[326],
                     dot_clocks[327], dot_clocks[328], dot_clocks[339]);
            $display("%s lines: 0=%0d 100=%0d 239=%0d 240=%0d 241=%0d 261=%0d (clocks, last field)",
                     tag, line_clocks[0], line_clocks[100], line_clocks[239],
                     line_clocks[240], line_clocks[241], line_clocks[261]);
        end
    endtask

    initial begin
        repeat (10) @(posedge clk);
        rst_n = 1;

        // ---- Phase 1: NTSC, non-interlaced, short line enabled
        @(negedge clk); dut.BGINTERLACE = 1'b0;
        reset_meas();
        wait_frames(4);
        measuring = 0;
        report_frames("ntsc-nonint", 4);
        // fields alternate even/odd; one of each must appear
        begin
            integer seen_even = 0, seen_odd = 0;
            for (int i = 1; i < 4; i++) begin   // frame 0 may start mid-field
                check(frame_lines[i] == 262, "ntsc-nonint lines/frame", frame_lines[i], 262);
                if (frame_field[i] == 0) begin
                    seen_even = 1;
                    check(frame_clocks[i] == 357368, "ntsc-nonint even-field clocks", frame_clocks[i], 357368);
                end else begin
                    seen_odd = 1;
                    check(frame_clocks[i] == 357364, "ntsc-nonint odd-field clocks (short line)", frame_clocks[i], 357364);
                end
            end
            check(seen_even && seen_odd, "ntsc-nonint both fields seen", seen_even + seen_odd, 2);
        end
        check(dot_clocks[0] == 4, "dot 0 clocks", dot_clocks[0], 4);
        check(dot_clocks[323] == 6, "dot 323 clocks (long dot)", dot_clocks[323], 6);
        check(dot_clocks[327] == 6, "dot 327 clocks (long dot)", dot_clocks[327], 6);
        check(line_clocks[100] == 1364, "line 100 clocks", line_clocks[100], 1364);

        // ---- Phase 2: NTSC interlaced: 263/262-line fields, no short line
        @(negedge clk); dut.BGINTERLACE = 1'b1;
        reset_meas();
        wait_frames(4);
        measuring = 0;
        report_frames("ntsc-int", 4);
        begin
            integer seen263 = 0, seen262 = 0;
            for (int i = 1; i < 4; i++) begin
                if (frame_lines[i] == 263) begin
                    seen263 = 1;
                    check(frame_clocks[i] == 263*1364, "ntsc-int 263-line clocks", frame_clocks[i], 263*1364);
                end else if (frame_lines[i] == 262) begin
                    seen262 = 1;
                    check(frame_clocks[i] == 262*1364, "ntsc-int 262-line clocks", frame_clocks[i], 262*1364);
                end else
                    check(0, "ntsc-int lines/frame", frame_lines[i], 262);
            end
            check(seen263 && seen262, "ntsc-int both field lengths seen", seen263 + seen262, 2);
        end

        // ---- Phase 3: DIS_SHORTLINE=1 suppresses the short line
        @(negedge clk); dut.BGINTERLACE = 1'b0; dis_shortline = 1;
        reset_meas();
        wait_frames(3);
        measuring = 0;
        report_frames("ntsc-noshort", 3);
        for (int i = 1; i < 3; i++)
            check(frame_clocks[i] == 357368, "ntsc DIS_SHORTLINE clocks", frame_clocks[i], 357368);
        dis_shortline = 0;

        if (errors == 0) begin
            $display("tb_ppu_timing: PASS");
            $finish;
        end else begin
            $display("tb_ppu_timing: %0d FAILURES", errors);
            $fatal(1);
        end
    end

    initial begin
        #40000000;
        $display("tb_ppu_timing: TIMEOUT (V=%0d H=%0d frames=%0d)", dut.V_CNT, dut.H_CNT, nframes);
        $fatal(1);
    end
endmodule
