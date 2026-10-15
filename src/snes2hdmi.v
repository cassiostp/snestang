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
    input sl_out,               // core_config[21]: dark output rows instead of an integer scale
    input [31:0] video_config,  // colour controls, CRT mask and smoothing, see video_fx.v, smooth.v (the LCD grid is unused)

	// video clocks
	input clk_pixel,
	input clk_5x_pixel,
	input locked,

    output reg pause_snes_for_frame_sync,

    // output [7:0] led,

	// output signals
	output       tmds_clk_n,
	output       tmds_clk_p,
	output [2:0] tmds_d_n,
	output [2:0] tmds_d_p
);

    localparam FRAMEWIDTH = 1280;       // 720P
    localparam FRAMEHEIGHT = 720;
    localparam TOTALWIDTH = 1650;
    localparam TOTALHEIGHT = 750;
    localparam SCALE = 5;
    localparam VIDEOID = 4;
    localparam VIDEO_REFRESH = 60.0;

    localparam IDIV_SEL_X5 = 3;
    localparam FBDIV_SEL_X5 = 54;
    localparam ODIV_SEL_X5 = 2;
    localparam DUTYDA_SEL_X5 = "1000";
    localparam DYN_SDIV_SEL_X5 = 2;
    
    localparam CLKFRQ = 74250;

    localparam AUDIO_BIT_WIDTH = 16;

    // video stuff
    wire [9:0] cy, frameHeight;
    wire [10:0] cx, frameWidth;
    reg active, r_active;
    wire [7:0] x, y;                    // SNES pixel position

    //
    // BRAM line buffer for 16 lines. Each pixel is 5:5:5 RGB
    // Each BRAM block holds 4 lines. So 16 lines needs 4 blocks.
    //
    localparam BUF_WIDTH = 5;        // 2 ^ BUF_WIDTH lines
    localparam BUF_SIZE = 1 << BUF_WIDTH;
    reg [14:0] mem [0:BUF_SIZE*256-1];
    reg [BUF_WIDTH+8-1:0] mem_portA_addr;
    reg [14:0] mem_portA_wdata;
    reg mem_portA_we;
    wire [BUF_WIDTH+8-1:0] mem_portB_addr;
    reg [14:0] mem_portB_rdata;
    reg mem_writeto = 1'b0;     // current line we are writing to. we read from the other line
   
    // We need to do a bit of synchronization as the SNES and HDMI run on separate clocks and they
    // do not align perfectly.
    // - Let SNES execute a bit faster (0.5%) than the HDMI stack. This way we always have enough pixels.
    // - For each frame, we let the SNES run until the first line is rendered, and written to line buffer.
    //   Then we pause the SNES and wait (through pause_snes_for_frame_sync) for HDMI to catch up.
    // - Once HDMI started the frame, start SNES again.
    reg sync_done = 1'b0;
    reg hdmi_first_line;
    wire [9:0] sl_pic_top;      // first row of the picture, from scanlines.v
    reg pause_sync;     // pause for even number of cycles for PPU sdram access to stay in sync
    reg hdmi_first_line_r, hdmi_first_line_rr;
    always @(posedge clk) begin
        hdmi_first_line_r <= hdmi_first_line;
        hdmi_first_line_rr <= hdmi_first_line_r;
        if (pause_snes_for_frame_sync) pause_sync <= ~pause_sync;
        if (~sync_done) begin
            if (~pause_snes_for_frame_sync) begin
                if (ys[7:0] == 8'd1 && snes_refresh) begin      // halt SNES after first line is buffered
                    pause_snes_for_frame_sync <= 1'b1;
                    pause_sync <= 0;
                end
            end else if (hdmi_first_line_rr && pause_sync) begin                 // HDMI frame start, now resume SNES
                pause_snes_for_frame_sync <= 1'b0;
                sync_done <= 1'b1;
            end
        end else
            pause_snes_for_frame_sync <= 1'b0;
        if (ys[7:0] == 8'd200) sync_done <= 1'b0;               // reset sync_done for next frame
    end
    always @(posedge clk_pixel) begin
        if (cy == sl_pic_top && cx >= 11'd160)      // the first row of the picture
            hdmi_first_line <= 1;
        else
            hdmi_first_line <= 0;
    end

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
    // COLOR_OUT, X_OUT = {OUT_X, DOT_CLK}). On a normal line the two agree, so
    // the latched sub pixel is written as before. On a hi-res line (BG mode
    // 5/6, or pseudo-hi-res with BLEND off) they differ, and the pair is
    // averaged per channel, round half up - what a CRT shows for the half-pixel
    // shifted sub screen, and close enough for true hi-res text. hires sampled
    // with the sub sub-pixel governs the pair, so a mid-pair change does not
    // split it.
    //
    reg r_dotclk, r_vblank, r_hblank;
    reg [14:0] sub_rgb;
    reg sub_hires;
    wire [5:0] blend_b = {1'b0, sub_rgb[14:10]} + {1'b0, rgb5[14:10]} + 6'd1;
    wire [5:0] blend_g = {1'b0, sub_rgb[9:5]} + {1'b0, rgb5[9:5]} + 6'd1;
    wire [5:0] blend_r = {1'b0, sub_rgb[4:0]} + {1'b0, rgb5[4:0]} + 6'd1;
    always @(posedge clk) begin
        r_dotclk <= dotclk;
        r_vblank <= vblank;
        mem_portA_we <= 1'b0;
        if (dotclk && ~r_dotclk) begin                             // sub sub-pixel: latch it
            sub_rgb <= rgb5;
            sub_hires <= hires;
        end else if (~dotclk && r_dotclk && ~hblank && ~vblank && ys[7:0] < 224) begin  // main: write the pair
            mem_portA_addr <= {ys[BUF_WIDTH-1:0], xs[8:1]};
            mem_portA_wdata <= (sub_hires == 1'b1) ? {blend_b[5:1], blend_g[5:1], blend_r[5:1]} : sub_rgb;
            mem_portA_we <= 1'b1;
        end
    end

    always @(posedge clk) begin
        r_hblank <= hblank;
        if (hblank & ~r_hblank) begin       // flip active line on hblank
            mem_writeto <= ~mem_writeto;
        end
    end
    

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
    wire [10:0] audio_limit = (audio_used >= FIFO_HI) ? AUDIO_PERIOD - 11'd1 :
                              (audio_used <= FIFO_LO) ? AUDIO_PERIOD + 11'd1 : AUDIO_PERIOD;

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
                clk_audio = ~clk_audio;     // generate audio clock @ 32Khz
                // output audio sample on posedge clk_audio
                if (!clk_audio && !audio_empty) begin
                    {audio_sample_word[0], audio_sample_word[1]} <= audio_sample;
                    audio_rinc <= 1'b1;
                end else if (!clk_audio && pause)
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
    // Scale 256x224 to 960x720 (4:3), see scanlines.v for the scanline geometry:
    // with scanlines on, 3 output rows per source line and 896x672, centred.
    // Nearest neighbour; smooth.v blends the source pixels (video_config[19:18]). For that the
    // line buffer is read twice per source column, the line to show and its neighbour line.
    // The neighbour is the line before or after the shown one, and both are in the buffer: the
    // frame sync halts the SNES half way through line 1 and releases it as the picture starts,
    // and it is ahead of the picture from then on (it writes a line faster than the picture
    // shows one), so a row only blends with the line after it once that has been written, and
    // the lead stays under the 31 lines the buffer holds (sim/video_fx/tb_snes_linebuf.v).
    //
    localparam LINES = 224;     // lines of the picture
    wire [23:0] rgb;            // actual RGB output
    reg [23:0] rgb_pre;         // before video_fx
    reg pic_pre;                // rgb_pre is a pixel of the picture, not the border or the overlay
    reg dark_pre;
    reg [7:0] xx;               // scaled-down pixel position
    reg [7:0] yy;
    reg [10:0] xcnt;
    reg [10:0] ycnt;            // fractional scaling counters
    reg [9:0] cy_r;

    // scanlines: sl_geom frames are scaled 3 rows per source line, 896x672
    // The LCD grid (video_config[15]) is not offered on the SNES: 3.5 output columns per source
    // pixel is not a whole number. Bit 15 is cleared for sl_rows and video_fx, so the picture
    // geometry never depends on it and the grid flags are tied low.
    wire sl_geom, sl_show, sl_dark, sl_last;
    wire [7:0] sl_yy;
    wire [1:0] sl_dk;
    sl_rows sl (
        .clk(clk_pixel), .cy(cy),
        .cfg_on(scanlines), .cfg_dark(sl_darkness), .cfg_thick(sl_thick), .cfg_out(sl_out),
        .cfg_grid(1'b0), .hide(overlay),
        .rows(3'd3), .dark_thin(3'd1), .dark_thick(3'd2), .lines(8'd224), .top(10'd24),
        .geom(sl_geom), .pic_top(sl_pic_top), .yy(sl_yy), .show(sl_show), .dark(sl_dark), .last(sl_last), .darkness(sl_dk)
    );
    reg [7:0] yy_s;             // source line to show
    always @(posedge clk_pixel) yy_s <= sl_geom ? sl_yy : yy;

    // smoothing: the line buffer is read for line yy_s and for yb_s, one clock each in turn
    wire [1:0] sm_mode;
    wire sm_rd_b;
    wire [23:0] sm_rgb;
    reg [7:0] yb_s;             // the neighbour line to blend with
    wire [7:0] ysel = sm_rd_b ? yb_s : yy_s;
    wire [7:0] xx_ov;           // xx, SM_LAT clocks old
    assign mem_portB_addr = {ysel[BUF_WIDTH-1:0], xx};
    assign overlay_x = xx_ov;
    assign overlay_y = yy_s;
    wire [11:0] XSIZE  = sl_geom ? 12'd896 : 12'd960;   // 4:3 on 720 rows, 4:3 on 672 rows
    wire [11:0] XSTART = (12'd1280 - XSIZE) >> 1;
    wire [11:0] XSTOP  = (12'd1280 + XSIZE) >> 1;

    // address calculation
    // Assume the video occupies fully on the Y direction, we are upscaling the video by `720/height`.
    // xcnt and ycnt are fractional scaling counters.
    // video_fx follows rgb_pre with FX_LAT register stages. Its first stage is the one that sl_dim
    // used to be (active started at XSTART - 2 then), so active starts FX_LAT - 1 clocks earlier
    // than that, at XSTART - 1 - FX_LAT. The smoothing is between the line buffer and rgb_pre:
    // rgb_pre comes SM_LAT clocks later than the line buffer alone would give it, so active starts
    // SM_LAT clocks earlier still. The xx/xcnt counters, and so the line buffer read address, run
    // with it; the overlay lookup address (xx_ov) and `active` are delayed back by SM_LAT, so the
    // picture, the overlay and the border land where they did. The source line (yy_s) only changes
    // at the start of an output row, long before active.
    localparam FX_LAT = 11;     // clocks from rgb_pre to rgb, see video_fx.v
    localparam SM_LAT = 9;      // the line buffer read is followed by a register, smooth.v (LAT 8) and the rgb_pre register
    reg cnew = 1'b0;            // the line buffer address is the first of a source column
    always @(posedge clk_pixel) begin
        reg active_t;
        reg [10:0] xcnt_next;
        reg [10:0] ycnt_next;
        xcnt_next = xcnt + 256;
        ycnt_next = ycnt + 224;

        active_t = 0;
        if ({1'b0, cx} == XSTART - 12'd1 - FX_LAT - SM_LAT) begin
            active_t = 1;
            active <= 1;
        end else if ({1'b0, cx} == XSTOP - 12'd1 - FX_LAT - SM_LAT) begin
            active_t = 0;
            active <= 0;
        end

        // the first source column starts with the first pixel, the others when xx changes
        cnew <= ({1'b0, cx} == XSTART - 12'd2 - FX_LAT - SM_LAT) | ((active_t | active) & (xcnt_next >= XSIZE));

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
            if (ycnt_next >= 720) begin
                ycnt <= ycnt_next - 720;
                yy <= yy + 1;
            end
        end

        if (cx == 0) begin
            xx <= 0;
            xcnt <= 0;
        end
        
        if (cy == 0) begin
            yy <= 0;
            ycnt <= 0;
        end 

    end

    // xx and active, delayed by SM_LAT
    reg [8*SM_LAT-1:0] xx_sh;
    reg [SM_LAT-1:0] act_sh;
    always @(posedge clk_pixel) begin
        xx_sh <= {xx_sh[8*SM_LAT-9:0], xx};
        act_sh <= {act_sh[SM_LAT-2:0], active};
    end
    assign xx_ov = xx_sh[8*SM_LAT-1 -: 8];
    wire active_d = act_sh[SM_LAT-1];

    // The weights of the blend, from the same counters (smooth.v). Horizontally the output pixel
    // is 256 of the 960 (896) units of a source pixel, vertically 224 of 720.
    localparam [16:0] KX_HALF_960 = (65536 * 128 + 960 / 2) / 960;
    localparam [16:0] KX_HALF_896 = (65536 * 128 + 896 / 2) / 896;
    localparam [16:0] KY_STEP = (65536 * 256 + 224 / 2) / 224;
    localparam [16:0] KY_HALF = (65536 * 128 + 720 / 2) / 720;
    wire [7:0] wx, wy_ax;
    wire hnext, vnext_ax;
    smooth_axis ax (
        .clk(clk_pixel), .mode(sm_mode), .pos(xcnt), .step(11'd256), .size(XSIZE),
        .k_step(17'd65536), .k_half(sl_geom ? KX_HALF_896 : KX_HALF_960),
        .first(xx == 8'd0), .last(xx == 8'd255), .w(wx), .next(hnext)
    );
    smooth_axis ay (
        .clk(clk_pixel), .mode(sm_mode), .pos(ycnt), .step(11'd224), .size(12'd720),
        .k_step(KY_STEP), .k_half(KY_HALF),
        .first(yy_s == 8'd0), .last(yy_s == LINES - 1), .w(wy_ax), .next(vnext_ax)
    );

    // Scanline frames show 3 rows per source line: soft blends the first and last row of a line
    // 1/3 towards the line before and after it. Sharp has nothing to blend, the rows are whole.
    reg sl_last_p, sl_show_p;           // the previous output row
    always @(posedge clk_pixel)
        if (cy[0] != cy_r[0]) begin
            sl_last_p <= sl_last;
            sl_show_p <= sl_show;
        end
    localparam [7:0] W_THIRD = 8'd85;   // round(256 / 3)
    wire row_first = ~sl_show_p | sl_last_p;
    wire geom_blend = (sm_mode == 2'd2) & ((row_first & (yy_s != 8'd0)) | (sl_last & (yy_s != LINES - 1)));
    wire [7:0] wy = sl_geom ? (geom_blend ? W_THIRD : 8'd0) : wy_ax;
    wire vnext = sl_geom ? sl_last : vnext_ax;
    always @(posedge clk_pixel)
        yb_s <= vnext ? ((yy_s == LINES - 1) ? yy_s : yy_s + 8'd1)
                      : ((yy_s == 8'd0) ? yy_s : yy_s - 8'd1);

    // the line buffer read as RGB8 (BGR5 to RGB8), and the first-of-column flag with it
    reg [23:0] buf_q;
    reg cn1, cn2;
    always @(posedge clk_pixel) begin
        buf_q <= {mem_portB_rdata[4:0], 3'b0, mem_portB_rdata[9:5], 3'b0, mem_portB_rdata[14:10], 3'b0};
        cn1 <= cnew;
        cn2 <= cn1;
    end

    smooth sm (
        .clk(clk_pixel), .cy(cy), .cfg(video_config[19:18]), .mode(sm_mode),
        .rd_b(sm_rd_b), .rd_rgb(buf_q), .col_new(cn2), .wx(wx), .hnext(hnext), .wy(wy),
        .rgb_out(sm_rgb)
    );

    // calc rgb value to hdmi
    always @(posedge clk_pixel) begin
        if (active_d & sl_show) begin
            if (overlay)
                rgb_pre <= {overlay_color[4:0],3'b0,overlay_color[9:5],3'b0,overlay_color[14:10],3'b0};      // BGR5 to RGB8
            else
                rgb_pre <= sm_rgb;
        end else
            rgb_pre <= 24'h303030;
        pic_pre <= active_d & sl_show & ~overlay;
        dark_pre <= active_d & sl_show & ~overlay & sl_dark;
    end

    // colour controls, the scanline darkening and the CRT mask
    video_fx fx (
        .clk(clk_pixel), .cx(cx), .cy(cy), .video_config({video_config[31:16], 1'b0, video_config[14:0]}),
        .rgb_in(rgb_pre), .pic_in(pic_pre), .dark_in(dark_pre), .darkness(sl_dk),
        .col_last_in(1'b0), .row_last_in(1'b0),
        .rgb_out(rgb)
    );

    // HDMI output.
    logic[2:0] tmds;

    hdmi #( .VIDEO_ID_CODE(VIDEOID), 
            .DVI_OUTPUT(0), 
            .VIDEO_REFRESH_RATE(VIDEO_REFRESH),
            .IT_CONTENT(1),
            .AUDIO_RATE(AUDIO_OUT_RATE), 
            .AUDIO_BIT_WIDTH(AUDIO_BIT_WIDTH),
            .START_X(0),
            .START_Y(0) )

    hdmi( .clk_pixel_x5(clk_5x_pixel), 
          .clk_pixel(clk_pixel), 
          .clk_audio(clk_audio),
          .rgb(rgb), 
          .reset( ~resetn ),
          .audio_sample_word(audio_sample_word),
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
