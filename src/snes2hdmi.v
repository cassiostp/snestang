// NES video and sound to HDMI converter
// nand2mario, 2022.9

`timescale 1ns / 1ps

module snes2hdmi (
	input clk,      // snes clock
	input resetn,

    // snes video and audio signals
    input dotclk,
    input hblank,
    input vblank,
    input [14:0] rgb5,
    input [8:0] xs, // {x,dotclk}
    input [8:0] ys, // {field,y}
    input hires,    // PPU HIGH_RES: the line holds 512 sub-pixels, sub then main per dotclk

    input overlay,
    output [7:0] overlay_x,
    output [7:0] overlay_y,
    input [14:0] overlay_color,

    input [15:0] audio_l,
    input [15:0] audio_r,
    input audio_ready,
    output audio_en,
    input pause,            // 1: emulator frozen (menu pause), output silence when the fifo drains

    // frame-sync pause happens during snes_refresh
    input snes_refresh,

    input scanlines,            // core_config[16]: scanlines on
    input [1:0] sl_darkness,    // core_config[19:18]: 25, 50, 75, 100 % dark
    input sl_thick,             // core_config[20]: thick lines
    input sl_out,               // core_config[21]: scale, 0 = integer, 1 = full
    input [31:0] video_config,  // colour controls and CRT mask, see video_fx.v (the LCD grid is unused)

	// video clocks
	input clk_pixel,
	input clk_5x_pixel,
	input locked,

    // 1: standard HDMI timing; 0: native rate (from video_std_timing in the top)
    input std_timing,

    output reg pause_snes_for_frame_sync,

    // output [7:0] led,

	// output signals
	output       tmds_clk_n,
	output       tmds_clk_p,
	output [2:0] tmds_d_n,
	output [2:0] tmds_d_p
);

`ifndef HZ120
`include "variant.vh"
`endif
`ifdef HZ120
    // 480p120 (VIC 48) at 54 MHz. 54e6 / (855 x 525) = 120.3008 Hz,
    // twice 60.1504 Hz: the largest whole-pixel line at or above twice the
    // SNES 60.0988 Hz that the console138k master clock can still lock
    // (free-run ~60.177 Hz). The 60 Hz build's native line is 60.1093 Hz;
    // 855 is 0.068 % faster than that and still never slower than the console.
    // console60k free-runs slower than 60.1504 Hz, so it cannot lock this rate.
    localparam FRAMEWIDTH = 720;
    localparam FRAMEHEIGHT = 480;
    localparam TOTALWIDTH = 858;
    localparam TOTALHEIGHT = 525;
    localparam SCALE = 5;
    localparam VIDEOID = 48;
    localparam VIDEO_REFRESH = 120.0;
    localparam NATIVE_LINE = 855;
`else
    localparam FRAMEWIDTH = 1280;       // 720P
    localparam FRAMEHEIGHT = 720;
    localparam TOTALWIDTH = 1650;
    localparam TOTALHEIGHT = 750;
    localparam SCALE = 5;
    localparam VIDEOID = 4;
    localparam VIDEO_REFRESH = 60.0;
`endif

    localparam IDIV_SEL_X5 = 3;
    localparam FBDIV_SEL_X5 = 54;
    localparam ODIV_SEL_X5 = 2;
    localparam DUTYDA_SEL_X5 = "1000";
    localparam DYN_SDIV_SEL_X5 = 2;
    
`ifdef HZ120
    localparam CLKFRQ = 54000;
`else
    localparam CLKFRQ = 74250;
`endif

    localparam AUDIO_BIT_WIDTH = 16;

    // video stuff
    wire [9:0] cy, frameHeight;
    wire [10:0] cx, frameWidth;
    reg active, r_active;
    wire [7:0] x, y;                    // SNES pixel position

`ifdef HZ120
    // BSRAM frame buffer, 256 x 240 x 15. One field of a 224-line or 239-line
    // picture. Hi-res (512) is blended to 256 at the write, the same as the
    // 60 Hz scaler: a raw 512-wide frame does not fit beside the rest of the
    // core. Interlace stores one field; a field longer than
    // the HDMI pair free-runs (freerun) and BFI is forced off so the game
    // is not slowed.
    //
    reg [14:0] mem [0:256*240-1];
    reg [15:0] mem_portA_addr;
    reg [14:0] mem_portA_wdata;
    reg mem_portA_we;
    wire [15:0] mem_portB_addr;
    reg [14:0] mem_portB_rdata;
`else
    // BRAM line buffer for 32 lines, 512 sub-pixels wide on hi-res lines.
    // Each pixel is 5:5:5 RGB. A normal line holds 256 pixels twice (sub and
    // main agree, so the pair is duplicated); a hi-res line (BG mode 5/6 or
    // pseudo-hi-res, PPU HIGH_RES) holds 512 distinct sub-pixels. The read
    // side shows normal lines as 256 (sub half, bit-identical to before) and
    // hi-res lines as 512 at full horizontal resolution. hires_lines holds
    // the HIGH_RES flag per buffer line, written with the pair.
    //
    localparam BUF_WIDTH = 5;        // 2 ^ BUF_WIDTH lines
    localparam BUF_SIZE = 1 << BUF_WIDTH;
    reg [14:0] mem [0:BUF_SIZE*512-1];
    reg [BUF_WIDTH+9-1:0] mem_portA_addr;
    reg [14:0] mem_portA_wdata;
    reg mem_portA_we;
    wire [BUF_WIDTH+9-1:0] mem_portB_addr;
    reg [14:0] mem_portB_rdata;
    reg [BUF_SIZE-1:0] hires_lines = {BUF_SIZE{1'b0}};
    reg mem_writeto = 1'b0;     // toggled on hblank (legacy, addressing uses ys/yy_s)
`endif
   
    // We need to do a bit of synchronization as the SNES and HDMI run on separate clocks and they
    // do not align perfectly.
    // - Let SNES execute a bit faster (0.5%) than the HDMI stack. This way we always have enough pixels.
    // - For each frame, we let the SNES run until the first line is rendered, and written to line buffer.
    //   Then we pause the SNES and wait (through pause_snes_for_frame_sync) for HDMI to catch up.
    // - Once HDMI started the frame, start SNES again.
    // (hz120: the SNES runs until the visible picture is in the frame
    // buffer, then waits for the release row of every second HDMI frame.)
    localparam RELEASE_ROW = 10'd64;   // hz120 only: the release row on the second HDMI frame of the pair
    localparam BFI_SWAP_FRAMES = 16'd1800;   // hz120 only: game frames between phase swaps (~30 s)
    reg sync_done = 1'b0;
    reg hdmi_first_line;
    wire [9:0] sl_pic_top;      // first row of the picture, from scanlines.v
    reg pause_sync;     // pause for even number of cycles for PPU sdram access to stay in sync
    reg hdmi_first_line_r, hdmi_first_line_rr;
    reg fl_missed = 1'b0;       // a release row passed with no halt waiting for it
    reg fl_old = 1'b0;
    reg [18:0] fl_age = 19'b0;  // clocks since the last release row (saturating)
    reg [18:0] late1 = {19{1'b1}}, late2 = {19{1'b1}};  // fl_age at the last two halt points
`ifdef HZ120
    // Frame lock at twice the game rate. Each game frame is read twice. The
    // release is late enough that the second read stays ahead of the writer
    // it starts, and early enough that the next lit read still finds its
    // lines already written (the writer is slower per line than the reader).
    // A frame that is not shorter than the HDMI pair (interlace, a slow
    // crystal, console60k at this line length) skips the halt, as before.
    reg freerun = 1'b0;         // halt skipped: this field is not locked, BFI stays off
    reg bfi_ins = 1'b0;         // 1 on the second HDMI frame of the pair (the release frame)
    reg bfi_phase = 1'b0;       // flips which of the pair is the inserted frame
    reg [15:0] bfi_swap_cnt = 16'd0;
    reg bfi_swap_pending = 1'b0;
    reg at_f0_q = 1'b0;
    reg at_rel_q = 1'b0;
    reg fr_r = 1'b0, fr_rr = 1'b0;
    wire [1:0] bfi_mode = (video_config[21:20] == 2'd3) ? 2'd1 : video_config[21:20];
`endif
    always @(posedge clk) begin
        hdmi_first_line_r <= hdmi_first_line;
        hdmi_first_line_rr <= hdmi_first_line_r;
        if (pause_snes_for_frame_sync) pause_sync <= ~pause_sync;
        fl_old <= hdmi_first_line_rr;
        if (hdmi_first_line_rr && ~fl_old) begin
            fl_age <= 19'b0;
            if (~pause_snes_for_frame_sync)
                fl_missed <= 1'b1;  // release rows seen while halted are releases, not misses
        end else if (~&fl_age)
            fl_age <= fl_age + 19'd1;
        if (~sync_done) begin
            if (~pause_snes_for_frame_sync) begin
`ifdef HZ120
                if (ys[7:0] == 8'd224 && snes_refresh) begin  // picture is in the buffer
                    // A miss whose release window has already closed, and which is
                    // at least as late as the one two samples ago, would wait a
                    // whole pair for the next release. That is the missed-release
                    // trap (interlace, console60k, a slow crystal). A halt that
                    // lands inside the window, or before the release, is a lock:
                    // the tracker is zeroed so the next miss skips. While
                    // acquiring, the tracker stays large and a miss still halts.
                    if (fl_missed && !hdmi_first_line_rr && fl_age >= late2) begin
                        sync_done <= 1'b1;
                        freerun <= 1'b1;
                    end else begin
                        pause_snes_for_frame_sync <= 1'b1;
                        pause_sync <= 0;
                        freerun <= 1'b0;
                    end
                    fl_missed <= 1'b0;
                    if (!fl_missed || hdmi_first_line_rr) begin
                        late2 <= 19'b0;
                        late1 <= 19'b0;
                    end else begin
                        late2 <= late1;
                        late1 <= fl_age;
                    end
                end
`else
                if (ys[7:0] == 8'd1 && snes_refresh) begin      // halt SNES after first line is buffered
                    // If the release row already passed, waiting for the next one would
                    // stall the SNES for almost a whole frame. That is right while
                    // acquiring (boot, menu, a geometry change: the halt point gets
                    // earlier every frame, fl_age shrinks) and wrong when the SNES
                    // frame is not shorter than the HDMI one (interlace: it gets
                    // later). Skip the halt only in the second case.
                    if (fl_missed && fl_age >= late2)
                        sync_done <= 1'b1;
                    else begin
                        pause_snes_for_frame_sync <= 1'b1;
                        pause_sync <= 0;
                    end
                    fl_missed <= 1'b0;
                    late2 <= late1;
                    late1 <= fl_missed ? fl_age : 19'b0;
                end
`endif
            end else if (hdmi_first_line_rr && pause_sync) begin                 // HDMI frame start, now resume SNES
                pause_snes_for_frame_sync <= 1'b0;
                sync_done <= 1'b1;
            end
        end else
            pause_snes_for_frame_sync <= 1'b0;
`ifdef HZ120
        if (ys[7:0] == 8'd0)
            sync_done <= 1'b0;               // re-arm at the next frame
`else
        if (ys[7:0] == 8'd200)
            sync_done <= 1'b0;               // reset sync_done for next frame
`endif
    end
`ifdef HZ120
    // One clk_pixel driver for the pair phase, the ~30 s swap and the release
    // row (Gowin rejects a reg written from two blocks).
    always @(posedge clk_pixel) begin
        fr_r <= freerun;
        fr_rr <= fr_r;
        at_f0_q <= (cy == 10'd0);
        if ((cy == 10'd0) && !at_f0_q) begin
            bfi_ins <= ~bfi_ins;
            if (bfi_swap_pending) begin
                bfi_phase <= ~bfi_phase;
                bfi_swap_pending <= 1'b0;
            end
        end
        hdmi_first_line <= (cy == RELEASE_ROW) && bfi_ins;
        at_rel_q <= (cy == RELEASE_ROW) && bfi_ins;
        if ((cy == RELEASE_ROW) && bfi_ins && !at_rel_q && (bfi_mode != 2'd0)) begin
            if (bfi_swap_cnt == BFI_SWAP_FRAMES - 1) begin
                bfi_swap_cnt <= 16'd0;
                bfi_swap_pending <= 1'b1;
            end else
                bfi_swap_cnt <= bfi_swap_cnt + 16'd1;
        end
    end
`else
    always @(posedge clk_pixel) begin
        if (cy == sl_pic_top && cx >= 11'd160)      // the first row of the picture
            hdmi_first_line <= 1;
        else
            hdmi_first_line <= 0;
    end
`endif

    // BRAM port A read/write
	always_ff @(posedge clk) begin
		if (mem_portA_we) begin
			mem[mem_portA_addr] <= mem_portA_wdata;
		end
	end

    // BRAM port B read
    always_ff @(posedge clk_pixel) begin
        mem_portB_rdata <= mem[mem_portB_addr];
    end

    integer j;
    initial begin
        // On power-up, fill line buffer with a gradient
        for (j = 0; j < 512; j=j+1) begin
            mem[j][14:10] = j;
            mem[j][9:5] = j;
            mem[j][4:0] = j;
        end
    end

    //
    // Data input. The PPU sends two sub-pixels per OUT_X: the sub-screen colour
    // while dotclk is high, the main-screen colour while it is low (ppu.v
    // COLOR_OUT, X_OUT = {OUT_X, DOT_CLK}), xs = {x, dotclk} 9 bits.
    //
    // hz120: on a normal line the two agree, so the latched sub pixel is
    // written as before. On a hi-res line (BG mode 5/6, or pseudo-hi-res with
    // BLEND off) they differ, and the pair is averaged per channel, round
    // half up - what a CRT shows for the half-pixel shifted sub screen.
    // hires sampled with the sub sub-pixel governs the pair, so a mid-pair
    // change does not split it. 512-wide does not fit in the frame buffer
    // (256x240x15 already 279/340 BSRAM; doubled ~330/340), so the blend stays.
    //
    // standard: 512-wide line buffer. Each sub-pixel is written at its own
    // xs (sub at {x,1} on the rise, main at {x,0} on the fall). Normal lines
    // hold each pixel twice (sub == main from the PPU) and read back as 256,
    // bit-identical to before; hi-res lines hold 512 distinct sub-pixels and
    // read back at full resolution. hires_lines records HIGH_RES per buffer
    // line, committed with the pair, so a mid-line toggle takes effect on the
    // next line.
    //
`ifdef HZ120
    reg r_dotclk, r_vblank;
`else
    reg r_dotclk, r_vblank, r_hblank;
`endif
    reg [14:0] sub_rgb;
    reg sub_hires;
    wire [5:0] blend_b = {1'b0, sub_rgb[14:10]} + {1'b0, rgb5[14:10]} + 6'd1;
    wire [5:0] blend_g = {1'b0, sub_rgb[9:5]} + {1'b0, rgb5[9:5]} + 6'd1;
    wire [5:0] blend_r = {1'b0, sub_rgb[4:0]} + {1'b0, rgb5[4:0]} + 6'd1;
    always @(posedge clk) begin
        r_dotclk <= dotclk;
        r_vblank <= vblank;
        mem_portA_we <= 1'b0;
`ifdef HZ120
        if (dotclk && ~r_dotclk) begin                             // sub sub-pixel: latch it
            sub_rgb <= rgb5;
            sub_hires <= hires;
        end else if (~dotclk && r_dotclk && ~hblank && ~vblank && ys[7:0] < 240) begin  // main: write the pair
            mem_portA_addr <= {ys[7:0], xs[8:1]};
            mem_portA_wdata <= (sub_hires == 1'b1) ? {blend_b[5:1], blend_g[5:1], blend_r[5:1]} : sub_rgb;
            mem_portA_we <= 1'b1;
        end
`else
        if (dotclk && ~r_dotclk) begin                             // sub sub-pixel: write it at {x,1}
            sub_rgb <= rgb5;
            sub_hires <= hires;
            if (~hblank && ~vblank && ys[7:0] < 224) begin
                mem_portA_addr <= {ys[BUF_WIDTH-1:0], xs};
                mem_portA_wdata <= rgb5;
                mem_portA_we <= 1'b1;
            end
        end else if (~dotclk && r_dotclk) begin                    // main sub-pixel: write it at {x,0}
            if (~hblank && ~vblank && ys[7:0] < 224) begin
                mem_portA_addr <= {ys[BUF_WIDTH-1:0], xs};
                mem_portA_wdata <= rgb5;
                mem_portA_we <= 1'b1;
                hires_lines[ys[BUF_WIDTH-1:0]] <= sub_hires;
            end
        end
`endif
    end

`ifdef HZ120
    // 239-line frames (overscan) are stored in the same buffer. tall is the
    // previous frame: a write at ys >= 224 marks it, latched as the frame ends.
    reg tall_seen = 1'b0;
    reg tall = 1'b0;
    reg ys_zero = 1'b0;
    always @(posedge clk) begin
        ys_zero <= (ys[7:0] == 8'd0);
        if ((ys[7:0] == 8'd0) && !ys_zero) begin
            tall <= tall_seen;
            tall_seen <= 1'b0;
        end
        if (mem_portA_we && ys[7:0] >= 8'd224)
            tall_seen <= 1'b1;
    end
`else
    always @(posedge clk) begin
        r_hblank <= hblank;
        if (hblank & ~r_hblank) begin       // flip active line on hblank
            mem_writeto <= ~mem_writeto;
        end
    end
`endif
    

    // HDMI TX audio - send 32K sampling rate audio
    // The DSP (ACLK_FREQ in dsp.vh) produces just enough samples per HDMI
    // frame to cover the consumption below plus the samples lost while the
    // frame sync halts the SNES once per frame. The FIFO level trims the
    // residual (clock tolerance): above FIFO_HI the audio period shortens by
    // one pixel clock, below FIFO_LO it lengthens by one, so the level stays
    // mid-FIFO and samples are neither dropped nor repeated.
    localparam AUDIO_OUT_RATE = 32000;
    localparam AUDIO_DELAY = CLKFRQ * 1000 / AUDIO_OUT_RATE / 2;
    localparam [10:0] AUDIO_PERIOD = AUDIO_DELAY - 1;    // pixel clocks per half audio clock
    localparam FIFO_ADDRSIZE = 6;       // 64 samples, ~2 ms at 32 kHz
    localparam [FIFO_ADDRSIZE:0] FIFO_LO = 20;
    localparam [FIFO_ADDRSIZE:0] FIFO_HI = 44;
    reg [15:0] audio_sample_word [1:0];
    reg [10:0] audio_divider;
    reg clk_audio;
    reg audio_rinc;
    wire audio_full, audio_empty;
    wire [FIFO_ADDRSIZE:0] audio_used;
    wire [31:0] audio_sample;
    // SNESSOUND8 diagnostic, not a candidate: no occupancy servo.
    wire [10:0] audio_limit = AUDIO_PERIOD;

    always @(posedge clk_pixel) begin
        if (!resetn) begin
            audio_divider <= 0;
            clk_audio <= 0;
            audio_rinc <= 0;
            audio_sample_word[0] <= 0;
            audio_sample_word[1] <= 0;
        end else begin
            audio_rinc <= 0;
            if (audio_divider < audio_limit)
                audio_divider <= audio_divider + 1;
            else begin
                audio_divider <= 0;
                // Nonblocking: with a blocking toggle the tests below read
                // the new value in simulation but the flop output in the
                // netlist, so sim and hardware latch on different edges
                // (and packet_picker can miss every edge in sim).
                clk_audio <= ~clk_audio;    // generate audio clock @ 32Khz
                // latch the next sample on the falling edge of clk_audio
                if (clk_audio && !audio_empty) begin
                    {audio_sample_word[0], audio_sample_word[1]} <= audio_sample;
                    audio_rinc <= 1'b1;
                end else if (clk_audio && pause)
                    // menu pause drained the fifo: output silence, not the last held sample
                    {audio_sample_word[0], audio_sample_word[1]} <= 32'd0;
            end
        end
    end

    // Audio sample FIFO for 64 samples
    dual_clk_fifo #(.DATESIZE(32), .ADDRSIZE(FIFO_ADDRSIZE)) audio_fifo (
        .clk(clk), .wrst_n(resetn),
        .winc(audio_ready), .wdata({audio_l, audio_r}), .wfull(audio_full),
        .rclk(clk_pixel), .rrst_n(resetn),
        .rinc(audio_rinc), .rdata(audio_sample), .rempty(audio_empty),
        .almost_full(), .almost_empty(), .rdusedw(audio_used)
    );

    //
    // Video
`ifdef HZ120
    // Scale 256x224 to 640x448 (2.5 x 2) centred in 720x480, or 256x239 to
    // 640x478 (top row 1) when the previous frame used overscan. Full scale
    // (core_config[21]) stretches the 224 (or 239) lines over the 480 rows.
    // Nearest neighbour.
    // The frame buffer holds the whole picture, so the shown line is valid
    // for the whole read.
    //
    wire [7:0] pic_lines = tall ? 8'd239 : 8'd224;
    wire [9:0] pic_top_i = tall ? 10'd1 : 10'd16;
`else
    // Scale 256x224 to 960x720 (4:3), see scanlines.v for the scanline geometry:
    // with the integer scale, 3 output rows per source line and 896x672, centred.
    // Nearest neighbour.
    //
`endif
    wire [23:0] rgb;            // actual RGB output
    reg [23:0] rgb_pre;         // before video_fx
    reg pic_pre;                // rgb_pre is a pixel of the picture, not the border or the overlay
    reg dark_pre;
    reg [8:0] xx;               // scaled-down pixel position (8 bits normal, 9 bits hi-res standard)
    reg [7:0] yy;
    reg [10:0] xcnt;
    reg [10:0] ycnt;            // fractional scaling counters
    reg [9:0] cy_r;

    // scanlines: sl_geom frames are scaled 3 rows per source line, 896x672
    // (hz120: 2 rows per source line, 640x448; thin and thick coincide).
    // The LCD grid (video_config[15]) is not offered on the SNES: 3.5 output columns per source
    // pixel is not a whole number. Bit 15 is cleared for sl_rows and video_fx, so the picture
    // geometry never depends on it and the grid flags are tied low.
    wire sl_geom, sl_show, sl_dark;
    wire [7:0] sl_yy;
    wire [1:0] sl_dk;
    sl_rows sl (
        .clk(clk_pixel), .cy(cy),
        .cfg_on(scanlines), .cfg_dark(sl_darkness), .cfg_thick(sl_thick), .cfg_out(sl_out),
        .cfg_grid(1'b0), .hide(overlay),
`ifdef HZ120
        .rows(3'd2), .dark_thin(3'd1), .dark_thick(3'd1), .lines(pic_lines), .top(pic_top_i),
`else
        .rows(3'd3), .dark_thin(3'd1), .dark_thick(3'd2), .lines(8'd224), .top(10'd24),
`endif
        .geom(sl_geom), .pic_top(sl_pic_top), .yy(sl_yy), .show(sl_show), .dark(sl_dark), .last(), .darkness(sl_dk)
    );
    reg [7:0] yy_s;             // source line to show
    always @(posedge clk_pixel) yy_s <= sl_geom ? sl_yy : yy;

`ifdef HZ120
    assign mem_portB_addr = {yy_s, xx[7:0]};
`else
    // Hi-res line shows 512 sub-pixels at full resolution; a normal line
    // shows 256 (the sub half, bit-identical to the blended build, since
    // sub == main from the PPU when HIGH_RES is 0).
    wire hires_cur = hires_lines[yy_s[BUF_WIDTH-1:0]];
    assign mem_portB_addr = hires_cur ? {yy_s[BUF_WIDTH-1:0], xx} : {yy_s[BUF_WIDTH-1:0], xx[7:0], 1'b1};
`endif
`ifdef HZ120
    assign overlay_x = xx[7:0];
`else
    assign overlay_x = hires_cur ? xx[8:1] : xx[7:0];
`endif
    assign overlay_y = yy_s;
`ifdef HZ120
    wire [11:0] XSIZE  = 12'd640;               // 2.5 x 256, centred in the 720 active pixels
    wire [11:0] XSTART = (12'd720 - XSIZE) >> 1;
    wire [11:0] XSTOP  = (12'd720 + XSIZE) >> 1;

    // address calculation
    // Assume the video occupies fully on the Y direction, we are upscaling the video by `480/height`.
`else
    // Normal: 256x224 to 960x720 Full (3.75x) or 896x672 Integer-geom (3.5x).
    // Hi-res: 512 wide to 1280 Full (2.5x, fills the width) or 1024 Integer
    // (2x, centred). Nearest neighbour. Non-hires lines are pixel-identical
    // to the blended build.
    wire [11:0] XSIZE  = hires_cur ? (sl_geom ? 12'd1024 : 12'd1280) : (sl_geom ? 12'd896 : 12'd960);
    wire [11:0] XSTART = hires_cur ? (sl_geom ? 12'd128  : 12'd0)   : (sl_geom ? 12'd192 : 12'd160);
    wire [11:0] XSTOP  = XSTART + XSIZE;

    // address calculation
    // Assume the video occupies fully on the Y direction, we are upscaling the video by `720/height`.
`endif
    // xcnt and ycnt are fractional scaling counters.
    // video_fx follows rgb_pre with FX_LAT register stages. Its first stage is the one that sl_dim
    // used to be (active started at XSTART - 2 then), so active starts FX_LAT - 1 clocks earlier
    // than that, at XSTART - 1 - FX_LAT. The xx/xcnt counters, and so the line buffer read address
    // and the overlay lookup, run with it. The source line (yy_s) only changes at the start of an
    // output row, long before active.
    localparam FX_LAT = 11;     // clocks from rgb_pre to rgb, see video_fx.v
`ifdef HZ120
    reg [7:0] lines_l = 8'd224; // source lines latched with the frame, for the stretch
`endif
    // Full hi-res starts at 0, so XSTART-1-FX_LAT underflows: wrap into the
    // previous line's blanking (cx counts frameWidth totals, 1650 std/1647 native).
    wire [11:0] frame_tot = {1'b0, frameWidth};
    wire [11:0] start_c = (XSTART >= 12'd12) ? (XSTART - 12'd12) : (XSTART + frame_tot - 12'd12);
    wire [11:0] stop_c = XSTOP - 12'd12;
    always @(posedge clk_pixel) begin
        reg active_t;
        reg [10:0] xcnt_next;
        reg [10:0] ycnt_next;
`ifdef HZ120
        xcnt_next = xcnt + 256;
`else
        xcnt_next = xcnt + (hires_cur ? 11'd512 : 11'd256);
`endif
`ifdef HZ120
        ycnt_next = ycnt + {3'b0, lines_l};
`else
        ycnt_next = ycnt + 224;
`endif

        active_t = 0;
        if ({1'b0, cx} == start_c) begin
            active_t = 1;
            active <= 1;
        end else if ({1'b0, cx} == stop_c) begin
            active_t = 0;
            active <= 0;
        end

        if (active_t | active) begin        // increment xx
            xcnt <= xcnt_next;
            if (xcnt_next >= XSIZE) begin
                xcnt <= xcnt_next - XSIZE;
                xx <= xx + 1;
            end
        end

        cy_r <= cy;
        if (cy[0] != cy_r[0]) begin         // increment yy at new lines
            ycnt <= ycnt_next;
`ifdef HZ120
            if (ycnt_next >= 480) begin
                ycnt <= ycnt_next - 480;
                if (yy != lines_l - 8'd1) yy <= yy + 1;
            end
`else
            if (ycnt_next >= 720) begin
                ycnt <= ycnt_next - 720;
                yy <= yy + 1;
            end
`endif
        end

        if (cx == 0) begin
            xx <= 0;
            xcnt <= 0;
        end
        
        if (cy == 0) begin
            yy <= 0;
            ycnt <= 0;
`ifdef HZ120
            lines_l <= pic_lines;
`endif
        end 

    end

`ifdef HZ120
    // Inserted BFI frame: black (modes 1 and 3) or half brightness (mode 2).
    // Mode 0 shows the picture on both refreshes. The menu overlay is exempt,
    // and a free-running field (interlace, a clock that cannot lock) is too.
    // The phase swap (bfi_phase) moves which refresh is inserted, so the LCD
    // does not integrate the picture on only one polarity.
    wire bfi_eff_ins = bfi_ins ^ bfi_phase;
    wire bfi_dark = bfi_eff_ins & (bfi_mode != 2'd0) & ~overlay & ~fr_rr;
    reg [23:0] rgb_norm;
    always @* begin
        if (active & sl_show) begin
            if (overlay)
                rgb_norm = {overlay_color[4:0],3'b0,overlay_color[9:5],3'b0,overlay_color[14:10],3'b0};
            else
                rgb_norm = {mem_portB_rdata[4:0], 3'b0, mem_portB_rdata[9:5], 3'b0, mem_portB_rdata[14:10], 3'b0};
        end else
            rgb_norm = 24'h303030;
    end
    always @(posedge clk_pixel) begin
        if (!bfi_dark)
            rgb_pre <= rgb_norm;
        else if (bfi_mode == 2'd2)
            rgb_pre <= {1'b0, rgb_norm[23:17], 1'b0, rgb_norm[15:9], 1'b0, rgb_norm[7:1]};
        else
            rgb_pre <= 24'h000000;
        pic_pre <= active & sl_show & ~overlay & ~bfi_dark;
        dark_pre <= active & sl_show & ~overlay & sl_dark & ~bfi_dark;
    end
`else
    // calc rgb value to hdmi
    always @(posedge clk_pixel) begin
        if (active & sl_show) begin
            if (overlay)
                rgb_pre <= {overlay_color[4:0],3'b0,overlay_color[9:5],3'b0,overlay_color[14:10],3'b0};      // BGR5 to RGB8
            else
                rgb_pre <= {mem_portB_rdata[4:0], 3'b0, mem_portB_rdata[9:5], 3'b0, mem_portB_rdata[14:10], 3'b0};
        end else
            rgb_pre <= 24'h303030;
        pic_pre <= active & sl_show & ~overlay;
        dark_pre <= active & sl_show & ~overlay & sl_dark;
    end
`endif

    // colour controls, the scanline darkening and the CRT mask
    video_fx fx (
        .clk(clk_pixel), .cx(cx), .cy(cy), .video_config({video_config[31:16], 1'b0, video_config[14:0]}),
        .rgb_in(rgb_pre), .pic_in(pic_pre), .dark_in(dark_pre), .darkness(sl_dk),
        .col_last_in(1'b0), .row_last_in(1'b0),
        .rgb_out(rgb)
    );

    // SNESSOUND8 diagnostic, not a candidate: 1 kHz at -18 dBFS.
    // Replace only the HDMI input words; keep the pixel-clock sample phase.
    reg [5:0] diagnostic_phase = 0;
    always @(posedge clk_pixel) begin
        if (!resetn)
            diagnostic_phase <= 0;
        else if (audio_divider >= audio_limit && clk_audio)
            diagnostic_phase <= diagnostic_phase == AUDIO_OUT_RATE/1000 - 1 ?
                                6'd0 : diagnostic_phase + 6'd1;
    end
    wire [15:0] diagnostic_tone = diagnostic_phase < AUDIO_OUT_RATE/2000 ?
                                  16'h1000 : 16'hf000;
    wire [15:0] diagnostic_audio_word [1:0];
    assign diagnostic_audio_word[0] = diagnostic_tone;
    assign diagnostic_audio_word[1] = diagnostic_tone;

    // HDMI output.
    logic[2:0] tmds;

    hdmi #( .VIDEO_ID_CODE(VIDEOID), 
            .DVI_OUTPUT(0), 
            .VIDEO_REFRESH_RATE(VIDEO_REFRESH),
            .IT_CONTENT(1),
            .AUDIO_RATE(AUDIO_OUT_RATE), 
            .AUDIO_BIT_WIDTH(AUDIO_BIT_WIDTH),
`ifdef HZ120
            // 54 MHz / (855 x 525) = 120.3008 Hz, twice 60.1504 Hz
            .NATIVE_FRAME_WIDTH(NATIVE_LINE),
`else
            // SNES native rate (60.0988 Hz): 74.25 MHz / (1647 x 750) = 60.1093 Hz
            .NATIVE_FRAME_WIDTH(1647),
`endif
            .START_X(0),
            .START_Y(0) )

    hdmi( .clk_pixel_x5(clk_5x_pixel), 
          .clk_pixel(clk_pixel), 
          .clk_audio(clk_audio),
          .rgb(rgb), 
          .reset( ~resetn ),
          .std_timing(std_timing),
          .audio_sample_word(diagnostic_audio_word),
          .tmds(tmds), 
          .tmds_clock(tmdsClk), 
          .cx(cx), 
          .cy(cy),
          .frame_width( frameWidth ),
          .frame_height( frameHeight ) );

    // Gowin LVDS output buffer
    ELVDS_OBUF tmds_bufds [3:0] (
        .I({clk_pixel, tmds}),
        .O({tmds_clk_p, tmds_d_p}),
        .OB({tmds_clk_n, tmds_d_n})
    );

endmodule
