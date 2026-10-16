/* 
 * Top level for snestang
 * nand2mario, 2023.6
 */

//`define STEP_TRACE

`ifndef CONFIG_V
`error "config.v must be read before snestang_top.v"
`endif

import configPackage::*;

module snestang_top (
    input sys_clk,
    input s0,

    // UART
    input UART_RXD,
    output UART_TXD,

    // HDMI TX
    output       tmds_clk_p,
    output       tmds_clk_n,
    output [2:0] tmds_d_p,
    output [2:0] tmds_d_n,

    // LED
    output [7:0] led,

    // MicroSD
    // output sd_clk,
    // inout  sd_cmd,      // MOSI
    // input  sd_dat0,     // MISO
    // output sd_dat1,
    // output sd_dat2,
    // output sd_dat3,

    // SPI flash
    // output flash_spi_cs_n,          // chip select
    // input flash_spi_miso,           // master in slave out
    // output flash_spi_mosi,          // mster out slave in
    // output flash_spi_clk,           // spi clock
    // output flash_spi_wp_n,          // write protect
    // output flash_spi_hold_n,        // hold operations

`ifdef CONTROLLER_SNES
    // snes controllers
    output joy1_strb,
    output joy1_clk,
    input joy1_data,
    output joy2_strb,
    output joy2_clk,
    input joy2_data,
`endif

`ifdef CONTROLLER_DS2
    // dualshock controllers
    output ds_clk,
    input ds_miso,
    output ds_mosi,
    output ds_cs,
    output ds_clk2,
    input ds_miso2,
    output ds_mosi2,
    output ds_cs2,
`endif

    // USB1 and USB2
`ifdef USB1
    inout usb1_dp,
    inout usb1_dn,
`endif
`ifdef USB2
    inout usb2_dp,
    inout usb2_dn,
`endif
    // SDRAM
    output O_sdram_clk,
    output O_sdram_cke,
    output O_sdram_cs_n,            // chip select
    output O_sdram_cas_n,           // columns address select
    output O_sdram_ras_n,           // row address select
    output O_sdram_wen_n,           // write enable
    inout [SDRAM_DATA_WIDTH-1:0] IO_sdram_dq,       // 31 bit bidirectional data bus
    output [SDRAM_ROW_WIDTH-1:0] O_sdram_addr,     // 11 bit multiplexed address bus
    output [SDRAM_DATA_WIDTH/8-1:0] O_sdram_dqm,       // 
    output [1:0] O_sdram_ba         // 4 banks
);

// Clock signals
wire mclk;                      // SNES master clock at 21.5054Mhz (~21.477)
wire fclk;                      // Fast clock for sdram for SDRAM
wire fclk_p;                    // 180-degree shifted fclk
wire clk27;                     // 27Mhz for hdmi clock generation
wire hclk5, hclk;               // 720p pixel clock at 74.25Mhz, and 5x high-speed

reg resetn = 1'b0;              // reset is cleared after 4 cycles
wire pause;                     // core_config[17]: freeze the core while the game menu is open
wire [31:0] core_config;        // from iosys
wire [31:0] video_config;       // from iosys
// Wall clock (frame 0x14, via iosys), packed into the S-RTC's nibble map
// by srtc_time_pack (the MiSTer hps_io RTC format SRTC.v reloads on).
// The S-RTC free-runs at 1 Hz between frames. Same mclk domain as iosys
// and the core. Like MiSTer, a game write to the S-RTC holds only until
// the next resync (10 s).
wire [31:0] time_unix;
wire [55:0] time_bcd;
wire [7:0]  time_solar, time_flags;
wire        time_strobe;
wire [64:0] ext_rtc;
srtc_time_pack time_pack(
    .time_bcd(time_bcd), .time_strobe(time_strobe), .ext_rtc(ext_rtc)
);
assign pause = core_config[17];

reg [15:0] resetcnt = 16'hffff;
always @(posedge mclk) begin
    resetcnt <= resetcnt == 0 ? 0 : resetcnt - 1;
     if (resetcnt == 0)
//  if (resetcnt == 0 && s0)   // primer25k, nano20k
//     if (resetcnt == 0 && ~s0)   // mega138k
        resetn <= 1'b1;
end

// rPLL for Tang Nano 20K
`ifdef PLL_R

// Clocks for Nano 20K
assign clk27 = sys_clk;
gowin_pll_hdmi pll_hdmi (
    .clkin(sys_clk),            // 27 Mhz input
    .clkout(hclk5)              // 371.25Mhz
);

CLKDIV #(.DIV_MODE(5)) div5 (
    .CLKOUT(hclk),              // 74.25Mhz
    .HCLKIN(hclk5),
    .RESETN(resetn),
    .CALIB(1'b0)
);

gowin_pll_snes pll_snes (
    .clkin(sys_clk),
    .clkout(fclk),              // 86.4
    .clkoutp(fclk_p),           // 225-degrees shifted
    .clkoutd(mclk)              // 21.6
);

`elsif VERILATOR
// Simulated clocks for verilator
reg [2:0] clk_cnt = 3'b0;       // 0 1 2 3 4 5
reg mclk_buf;                   // 0 0 0 1 1 1
assign fclk = clk_cnt[0];       // 0 1 0 1 0 1
assign mclk = mclk_buf;
always @(posedge sys_clk) begin
    clk_cnt <= clk_cnt + 3'b1; 
    if (clk_cnt == 3'd5) begin
        clk_cnt <= 0;
        mclk_buf <= 0;
    end
    if (clk_cnt == 3'd2)
        mclk_buf <= 1;
end

`else
// Mega 138K: mclk=21.5054, fclk=64.5161
// Primer 25K: mclk=21.4844, fclk=85.9375
gowin_pll_snes pll_snes (
    .clkout0(mclk),             // 21.4844
    .clkout1(fclk),
    .clkout2(fclk_p),
    .clkin(sys_clk)             // 50 Mhz input
);

// HDMI clocks
gowin_pll_27 pll_27 (
    .clkin(sys_clk),
    .clkout0(clk27)
);
gowin_pll_hdmi pll_hdmi (
    .clkin(clk27),              // 27 Mhz input
    .clkout0(hclk5), .clkout1(hclk)
);

`endif

wire [23:0] ROM_ADDR;
wire ROM_CE_N, ROM_OE_N, ROM_WE_N, ROM_WORD;
wire [15:0] ROM_D;
// ROM_Q normally comes from the CPU lane's sticky word (byte-selected by
// ROM_ADDR[0], since CX4/LoROM fetches are byte-wide). While the CX4 owns
// the ROM bus its own fetches come from the CPU2 lane through the word
// cache below instead, so a coinciding S-CPU WRAM request can no longer
// cancel the ROM fetch (and the CX4 waits for the word anyway).
wire [15:0] ROM_Q;
wire [15:0] rom_word_cpu2;
wire        cx4_owns_rom;
wire [15:0] rom_word = cx4_owns_rom ? rom_word_cpu2 : cpu_port0;
assign      ROM_Q = (ROM_WORD || ~ROM_ADDR[0]) ? rom_word : { rom_word[7:0], rom_word[15:8] };

wire [16:0] WRAM_ADDR;
wire        WRAM_CE_N;
wire        WRAM_OE_N;
wire        WRAM_RD_N;
wire        WRAM_WE_N;
wire  [7:0] WRAM_SD_Q = WRAM_ADDR[0] ? cpu_port1[15:8] : cpu_port1[7:0];
wire  [7:0] WRAM_Q;
wire  [7:0] WRAM_D;
wire        wram_rd = ~WRAM_CE_N & ~WRAM_RD_N;
wire        wram_wr = ~WRAM_CE_N & ~WRAM_WE_N;

wire [19:0] BSRAM_ADDR;
wire        BSRAM_CE_N;
wire        BSRAM_OE_N;
wire        BSRAM_WE_N;
wire        BSRAM_RD_N;
// The SNES reads the controller's sticky read register directly. Once the save
// channel uses the port, that register holds save-channel bytes, so the SNES
// sees the value from its own last access until it makes a new one.
wire  [7:0] bsram_dout;            // the sdram controller's BSRAM read register
reg   [7:0] snes_bsram_hold = 0;
reg         snes_bsram_shadow = 0;
// SA-1: its own ROM lane (served from the SDRAM CPU2 port through the word
// cache below) and BW-RAM in block RAM instead of the SDRAM save RAM.
wire [22:0] sa1_rom_addr;
wire        sa1_rom_req;
wire [15:0] sa1_rom_q;
wire        sa1_rom_wait;
`ifdef CHIP_SA1
wire        sa1_mode = rom_type[7:4] == 4'h6;
`else
wire        sa1_mode = 1'b0;
`endif
// CX4: its own ROM fetches (cache fill, DMA source read, external ROM read)
// ride the same CPU2 lane while the CX4 owns the ROM bus. SA-1 and CX4 never
// share a cartridge (rom_type 6 vs 4), so the two caches mux the one lane.
wire        cx4_rom_req;
wire [15:0] cx4_rom_q;
wire        cx4_rom_wait;
`ifdef CHIP_CX4
wire        cx4_mode = rom_type[7:4] == 4'h4;
`else
wire        cx4_mode = 1'b0;
`endif
assign      cx4_owns_rom = cx4_mode & cx4_rom_req;
assign      rom_word_cpu2 = cx4_owns_rom ? cx4_rom_q : sa1_rom_q;
wire  [7:0] bwram_q_a;             // SA-1 BW-RAM (block RAM) read data
wire  [7:0] BSRAM_Q = sa1_mode ? bwram_q_a : (snes_bsram_shadow ? snes_bsram_hold : bsram_dout);
wire  [7:0] BSRAM_D;

wire [15:0] VRAM1_ADDR;
wire        VRAM1_WE_N;
wire  [7:0] VRAM1_D, VRAM1_Q;
wire [15:0] VRAM2_ADDR;
wire        VRAM2_WE_N;
wire  [7:0] VRAM2_D, VRAM2_Q;
wire        VRAM_OE_N;

wire [15:0] ARAM_ADDR;
wire        ARAM_CE_N;
wire        ARAM_OE_N;
wire        ARAM_WE_N;
wire [15:0] aram_dout;
wire  [7:0] ARAM_Q = ARAM_ADDR[0] ? aram_dout[15:8] : aram_dout[7:0];
wire  [7:0] ARAM_D;
wire        aram_16 = 0;

wire BLEND = 1'b0;
reg        PAL;
wire       hires;
wire       dotclk  /*verilator public*/;
wire [14:0] rgb_out  /*verilator public*/;
wire [8:0] x_out /*verilator public*/, y_out /*verilator public*/;
wire       hblankn,vblankn;

wire [15:0] audio_l /*verilator public*/, audio_r /*verilator public*/;
wire audio_ready /*verilator public*/;
wire audio_en /*XXX synthesis syn_keep=1 */;

wire snes_joy_strb;
wire snes_joy1_clk, snes_joy2_clk;
wire [1:0] snes_joy1_di, snes_joy2_di;

// OR together when both SNES and DS2 controllers are connected (right now only nano20k supports both simultaneously)
wire [11:0] joy1_btns_ds2, joy2_btns_ds2;
wire [11:0] joy1_btns_snes, joy2_btns_snes;
wire [11:0] joy1_usb, joy2_usb;
wire [11:0] hid1, hid2;

wire [5:0] ph;
reg snes_start = 1'b0;
wire pause_snes_for_frame_sync;

// Selects the standard 60 Hz HDMI timing (for displays that refuse the native
// rate; a menu option for it may come later). Tied 0: the game runs at the
// console's own refresh rate.
wire video_std_timing = 1'b0;

wire [7:0] loader_do;
wire loader_do_valid, loading, header_finished;

reg [22:0] loader_addr = 0;

reg [7:0] dbg_reg, dbg_sel; 
wire [7:0] dbg_dat_out, dbg_dat_in;
reg dbg_reg_wr = 0;
reg dbg_break = 0;

wire [7:0] rom_type;
wire [3:0] rom_size, ram_size;
wire [23:0] rom_mask, ram_mask;

wire sdram_busy;
wire refresh;
reg enable; // && ~dbg_break;
reg loaded;

always @(posedge mclk) begin        // wait until memory initialize to start SNES
    if (~sdram_busy && ~pause_snes_for_frame_sync && ~pause && loaded)
        enable <= 1;
    else 
        enable <= 0;
end

wire sysclkf_ce, sysclkr_ce;
wire overlay;
// No buttons reach the console while the menu is up, or while core_config[22]
// asks (the firmware's scanline preview runs the game with the menu hidden).
wire pads_muted = overlay | core_config[22];

`ifdef CHIP_DSPn
parameter USE_DSPn=1;
`else
parameter USE_DSPn=0;
`endif
`ifdef CHIP_GSU
parameter USE_GSU=1;
`else
parameter USE_GSU=0;
`endif
`ifdef CHIP_CX4
parameter USE_CX4=1;
`else
parameter USE_CX4=0;
`endif
`ifdef CHIP_SA1
parameter USE_SA1=1;
`else
parameter USE_SA1=0;
`endif

// `ifdef VERILATOR
// parameter USE_DSPn=1;
// parameter USE_GSU=1;
// `endif

`ifndef DISABLE_SNES
main #(.USE_DSPn(USE_DSPn), .USE_GSU(USE_GSU), .USE_CX4(USE_CX4), .USE_SA1(USE_SA1)) main (
    .MCLK(mclk), .RESET_N(resetn & ~loading), .ENABLE(enable), 
    .SYSCLKF_CE(sysclkf_ce), .SYSCLKR_CE(sysclkr_ce), .REFRESH(refresh),

    .ROM_TYPE(rom_type), .ROM_MASK(rom_mask), .RAM_MASK(ram_mask),

    .ROM_ADDR(ROM_ADDR), .ROM_D(ROM_D), .ROM_Q(ROM_Q),
    .ROM_CE_N(ROM_CE_N), .ROM_OE_N(ROM_OE_N), .ROM_WE_N(ROM_WE_N),
    .ROM_WORD(ROM_WORD),

    .SA1_ROM_ADDR(sa1_rom_addr), .SA1_ROM_REQ(sa1_rom_req),
    .SA1_ROM_Q(sa1_rom_q), .SA1_ROM_WAIT(sa1_rom_wait),

    .CX4_ROM_REQ(cx4_rom_req), .CX4_ROM_WAIT(cx4_rom_wait),

    .BSRAM_ADDR(BSRAM_ADDR), .BSRAM_D(BSRAM_D),	.BSRAM_Q(BSRAM_Q),
    .BSRAM_CE_N(BSRAM_CE_N), .BSRAM_OE_N(BSRAM_OE_N), .BSRAM_WE_N(BSRAM_WE_N),
    .BSRAM_RD_N(BSRAM_RD_N),

    .WRAM_ADDR(WRAM_ADDR), .WRAM_D(WRAM_D),	.WRAM_Q(WRAM_SD_Q),
    .WRAM_CE_N(WRAM_CE_N), .WRAM_OE_N(WRAM_OE_N), .WRAM_WE_N(WRAM_WE_N),
    .WRAM_RD_N(WRAM_RD_N),

    .VRAM1_ADDR(VRAM1_ADDR), .VRAM1_DI(VRAM1_Q), .VRAM1_DO(VRAM1_D),
    .VRAM1_WE_N(VRAM1_WE_N), .VRAM2_ADDR(VRAM2_ADDR), .VRAM2_DI(VRAM2_Q),
    .VRAM2_DO(VRAM2_D), .VRAM2_WE_N(VRAM2_WE_N), .VRAM_OE_N(VRAM_OE_N),

    .ARAM_ADDR(ARAM_ADDR), .ARAM_Q(ARAM_Q), .ARAM_D(ARAM_D), 
    .ARAM_CE_N(ARAM_CE_N), .ARAM_OE_N(ARAM_OE_N), .ARAM_WE_N(ARAM_WE_N),

    .BLEND(BLEND), .PAL(PAL), .HIGH_RES(hires), .FIELD(), .INTERLACE(), .DIS_SHORTLINE(),
    .DOTCLK(dotclk), .RGB_OUT(rgb_out), .HBLANKn(hblankn),
    .VBLANKn(vblankn), .X_OUT(x_out), .Y_OUT(y_out),

    .JOY1_DI(pads_muted?2'b11:snes_joy1_di), .JOY2_DI(pads_muted?2'b11:snes_joy2_di), .JOY_STRB(snes_joy_strb), 
    .JOY1_CLK(snes_joy1_clk), .JOY2_CLK(snes_joy2_clk), 

    .AUDIO_L(audio_l), .AUDIO_R(audio_r), .AUDIO_READY(audio_ready), .AUDIO_EN(audio_en),

    .JOY1_P6(), .JOY2_P6(), .JOY2_P6_in(), .DOT_CLK_CE(DOT_CLK_CE), .EXT_RTC(ext_rtc),
    .SPC_MODE(), .IO_ADDR(), .IO_DAT(), .IO_WR(), 

    .DBG_SEL(dbg_sel), .DBG_REG(dbg_reg), .DBG_REG_WR(dbg_reg_wr), .DBG_DAT_IN(dbg_dat_in), 
    .DBG_DAT_OUT(dbg_dat_out), .DBG_BREAK(dbg_break)
);
`endif

// SDRAM for SNES ROM, WRAM and ARAM
wire [15:0] cpu_port0;
wire [15:0] cpu_port1;
reg         cpu_port;

reg         cpu_req;
reg  [1:0]  cpu_ds;
reg [15:0]  cpu_din;
reg [22:0]  cpu_addr; 
reg         cpu_we;

wire [22:0] rom_addr = loading ? loader_addr : ROM_ADDR[22:0];
reg [22:0]  rom_addr_sd;

// Second ROM reader on the controller's CPU2 lane (the SA-1's ROM fetches,
// served below the S-CPU; driven by the word cache below). The CX4's own
// fetches share the lane while the CX4 owns the ROM bus (the two chips never
// share a cartridge); the S-CPU lane stays for WRAM and for S-CPU ROM reads
// while the CX4 is idle.
wire [22:1] sa1_cpu2_addr, cx4_cpu2_addr, cpu2_addr;
wire        sa1_cpu2_req, cx4_cpu2_req, cpu2_req;
assign      cpu2_addr = sa1_mode ? sa1_cpu2_addr : cx4_cpu2_addr;
assign      cpu2_req  = sa1_mode ? sa1_cpu2_req  : cx4_cpu2_req;
wire        cpu2_req_ack;
wire [15:0] cpu2_dout;

reg [16:0]  wram_addr_sd;
reg         wram_wr_r, wram_rd_r;

reg         bsram_we;
reg [19:0]  bsram_addr;
reg [7:0]   bsram_din;
wire        bsram_rd = ~BSRAM_CE_N & (~BSRAM_RD_N || rom_type[7:4] == 4'hC || rom_type[7:4] == 4'h7);	// OBC-1/GSU read BSRAM outside CPU read cycles
wire        bsram_wr = ~BSRAM_CE_N & ~BSRAM_WE_N;
reg         bsram_rd_r, bsram_wr_r;

wire        aram_rd = ~ARAM_CE_N & ~ARAM_OE_N;
wire        aram_wr = ~ARAM_CE_N & ~ARAM_WE_N;
reg [15:0]  aram_addr_sd;
reg [15:0]  aram_din_sd;
reg         aram_we_sd;
reg         aram_rd_r, aram_wr_r;
reg         aram_req;

wire        DOT_CLK_CE;
assign      O_sdram_clk = fclk_p;

// Generate SDRAM signals
always @(posedge mclk) begin
    if (~resetn) begin
    end else begin
        
        // ROM read and load. While the CX4 owns the ROM bus its fetch address
        // is on ROM_ADDR: the CPU lane skips it (the CX4 reads the same word
        // through the CPU2 cache instead), so a coinciding S-CPU WRAM request
        // can no longer cancel the ROM fetch. S-CPU ROM reads while the CX4
        // is idle still use this lane exactly as before.
        if (loading && loader_do_valid && header_finished && loader_addr[0]
            || ~loading && ~ROM_CE_N && rom_addr_sd != rom_addr && ~cx4_owns_rom) begin
            rom_addr_sd <= rom_addr;
            cpu_addr <= rom_addr;
            cpu_req <= ~cpu_req;
            cpu_we <= loading;
            cpu_din <= {loader_do, loader_do_r};    // write 16 bits on odd addresses
            cpu_ds <= 2'b11;
            cpu_port <= 0;
        end
        
        // WRAM read/write
        wram_rd_r <= wram_rd; wram_wr_r <= wram_wr;
        if ((wram_rd && WRAM_ADDR[16:1] != wram_addr_sd[16:1]) || (wram_rd & ~wram_rd_r) || (wram_wr & ~wram_wr_r)) begin
            wram_addr_sd <= WRAM_ADDR;
            cpu_req <= ~cpu_req;
            cpu_addr <= {6'b111_111, WRAM_ADDR[16:0]};  // 7E,7F:0000-FFFF, total 128KB
            cpu_we <= wram_wr;
            cpu_ds <= {WRAM_ADDR[0], ~WRAM_ADDR[0]};
            cpu_din <= {WRAM_D, WRAM_D};        
            cpu_port <= 1;
        end 

        // BSRAM read/write. The save-RAM bridge below serializes these with the
        // save channel's accesses; snes_bs_tog just marks a new pending access.
        bsram_rd_r <= bsram_rd; bsram_wr_r <= bsram_wr;
        if (bsram_rd && BSRAM_ADDR != bsram_addr || (bsram_wr & ~bsram_wr_r) || (bsram_rd & ~bsram_rd_r)) begin
            bsram_addr <= BSRAM_ADDR;
            snes_bs_tog <= ~snes_bs_tog;
            bsram_din <= BSRAM_D;
            bsram_we <= bsram_wr;
        end

        // ARAM read/write. The controller is fed the address/data/we
        // snapshot taken on the toggle edge (not the combinational DSP/SMP
        // outputs), so the mclk->fclk ARAM path starts at flip-flops; the
        // DSP/SMP sees the same latency, the snapshot is the same edge's
        // values. Proven window: sim/sdram_port/run_stable.sh.
        aram_rd_r <= aram_rd; aram_wr_r <= aram_wr;
        if (aram_rd && aram_addr_sd != ARAM_ADDR || (aram_wr && aram_addr_sd != ARAM_ADDR) || (aram_rd & ~aram_rd_r) || (aram_wr & ~aram_wr_r)) begin
            aram_req <= ~aram_req;
            aram_addr_sd <= ARAM_ADDR;
            aram_din_sd <= {ARAM_D, ARAM_D};
            aram_we_sd <= aram_wr;
        end
    end
end

// save channel <-> bridge (driven by iosys when MCU_BL616; quiet zeros otherwise)
`ifdef CHIP_SA1
localparam SAVE_AW = 18;    // SA-1 BW-RAM saves reach 256 KB
`else
localparam SAVE_AW = 17;
`endif
wire [SAVE_AW-1:0] sv_addr;
wire [7:0]  sv_din;
wire        sv_req, sv_rreq;

// ---- Save-RAM <-> BSRAM bridge ----------------------------------------------
// The SNES cartridge bus and the iosys save channel both need the sdram
// controller's single BSRAM port (the 128 KB at the start of bank 1). The SNES
// edge detector above toggles snes_bs_tog when it has a new access; the save
// channel toggles sv_req (write) / sv_rreq (read). This arbiter owns the
// controller's req/ack pair and serves one byte at a time, SNES first: save
// accesses only slip into idle slots, so the SNES never queues behind one,
// while a SNES access arriving mid-save-byte waits ~6 clocks -- the SNES
// cartridge window is many times that. The controller toggles bs_req_ack once
// per access (fclk domain, like the existing cpu/aram handshakes); it is
// synchronized here and routed back to whichever source was served. Reads
// capture the controller's sticky bsram_dout before the next access can
// overwrite it, since the arbiter keeps the port until the byte is banked.
reg         snes_bs_tog = 0, snes_bs_seen = 0;
reg         sv_w_seen = 0, sv_r_seen = 0;
reg         bs_req_tog = 0;                 // -> controller .bsram_req
wire        bs_req_ack;                     // <- controller .bsram_req_ack
reg  [2:0]  bs_ack_sync = 0;                // 2FF sync of bs_req_ack into mclk
wire        bs_ack = bs_ack_sync[2];
reg         bs_busy = 0;
reg         bs_owner = 0;                   // 0: SNES access, 1: save access
reg         bs_we_r = 0;
reg  [16:0] bs_addr_r = 0;
reg  [7:0]  bs_din_r = 0;
reg         sv_ack_r = 0, sv_rack_r = 0;    // toggles back into iosys
reg  [7:0]  sv_q_r = 0;
wire        snes_bs_new = snes_bs_tog != snes_bs_seen;
wire        sv_w_new    = sv_req != sv_w_seen;
wire        sv_r_new    = sv_rreq != sv_r_seen;
wire        bs_free     = bs_req_tog == bs_ack;
wire        bs_issue_ok = ~bs_busy | bs_free;   // idle, or acked this very clock

always @(posedge mclk) begin
    bs_ack_sync <= {bs_ack_sync[1:0], bs_req_ack};
    if (sa1_mode) begin                 // the BW-RAM block RAM serves both sides
        snes_bs_seen <= snes_bs_tog;
        sv_w_seen <= sv_req;
        sv_r_seen <= sv_rreq;
    end
    if (bs_busy && bs_free) begin               // the access just completed
        bs_busy <= 0;
        if (bs_owner) begin
            if (bs_we_r) sv_ack_r <= ~sv_ack_r;
            else begin
                sv_q_r <= bsram_dout;           // the controller's sticky read reg
                sv_rack_r <= ~sv_rack_r;
            end
        end
    end
    if (bs_issue_ok && snes_bs_new && ~sa1_mode) begin
        snes_bsram_shadow <= 0;                 // the SNES gets the port's data again
        bs_addr_r <= bsram_addr[16:0];
        bs_din_r  <= bsram_din;
        bs_we_r   <= bsram_we;
        bs_owner  <= 0;
        bs_busy   <= 1;
        bs_req_tog <= ~bs_req_tog;
        snes_bs_seen <= snes_bs_tog;
    end else if (bs_issue_ok && sv_w_new && ~sa1_mode) begin
        if (!snes_bsram_shadow) begin           // keep the SNES's last read data
            snes_bsram_hold <= bsram_dout;
            snes_bsram_shadow <= 1;
        end
        bs_addr_r <= sv_addr[16:0];
        bs_din_r  <= sv_din;
        bs_we_r   <= 1;
        bs_owner  <= 1;
        bs_busy   <= 1;
        bs_req_tog <= ~bs_req_tog;
        sv_w_seen <= sv_req;
    end else if (bs_issue_ok && sv_r_new && ~sa1_mode) begin
        if (!snes_bsram_shadow) begin           // keep the SNES's last read data
            snes_bsram_hold <= bsram_dout;
            snes_bsram_shadow <= 1;
        end
        bs_addr_r <= sv_addr[16:0];
        bs_din_r  <= 8'h0;
        bs_we_r   <= 0;
        bs_owner  <= 1;
        bs_busy   <= 1;
        bs_req_tog <= ~bs_req_tog;
        sv_r_seen <= sv_rreq;
    end
end
wire sv_core_we = bsram_wr & ~bsram_wr_r;       // the SNES wrote save RAM

// ---- SA-1: ROM word cache on CPU2, BW-RAM in block RAM ----------------------
// In SA-1 mode the save channel talks to the BW-RAM's second port (through
// the small FSM here) instead of the SDRAM bridge above, which stays out of
// the way: it never issues, and its seen-toggles track the requests so a
// later non-SA-1 game starts clean. BSRAM_Q (above) likewise switches to
// the BW-RAM. The iosys save handshake sees the muxed ack/data.
wire        bw_sv_ack, bw_sv_rack;
wire  [7:0] bw_sv_q;
wire        sv_ack  = sa1_mode ? bw_sv_ack  : sv_ack_r;
wire        sv_rack = sa1_mode ? bw_sv_rack : sv_rack_r;
wire  [7:0] sv_q    = sa1_mode ? bw_sv_q    : sv_q_r;

`ifdef CHIP_SA1
sa1_rom_cache sa1_rom_cache (
    .mclk(mclk), .resetn(resetn), .active(sa1_mode & ~loading),
    .rom_addr(sa1_rom_addr), .rom_req(sa1_rom_req),
    .rom_q(sa1_rom_q), .rom_wait(sa1_rom_wait),
    .cpu2_addr(sa1_cpu2_addr), .cpu2_req(sa1_cpu2_req),
    .cpu2_req_ack(cpu2_req_ack), .cpu2_dout(cpu2_dout)
);

reg [17:0]  bw_addr_b = 0;
reg  [7:0]  bw_din_b = 0;
reg         bw_we_b = 0;
reg         bw_ack_r = 0, bw_rack_r = 0;
reg  [7:0]  bw_q_r = 0;
reg         bw_w_seen = 0, bw_r_seen = 0;
reg         bw_wr_pend = 0, bw_rd_pend = 0, bw_rd_valid = 0;
wire [7:0]  bwram_q_b;

always @(posedge mclk) begin
    if (bw_wr_pend) begin               // the write landed at this edge
        bw_we_b <= 0;
        bw_wr_pend <= 0;
        bw_ack_r <= ~bw_ack_r;
    end else if (bw_rd_valid) begin     // q_b held the byte through last cycle
        bw_rd_valid <= 0;
        bw_q_r <= bwram_q_b;
        bw_rack_r <= ~bw_rack_r;
    end else if (bw_rd_pend) begin      // address is on the port; data next cycle
        bw_rd_pend <= 0;
        bw_rd_valid <= 1;
    end else if (sa1_mode && sv_req != bw_w_seen) begin
        bw_w_seen <= sv_req;
        bw_addr_b <= sv_addr[17:0];
        bw_din_b <= sv_din;
        bw_we_b <= 1;
        bw_wr_pend <= 1;
    end else if (sa1_mode && sv_rreq != bw_r_seen) begin
        bw_r_seen <= sv_rreq;
        bw_addr_b <= sv_addr[17:0];
        bw_rd_pend <= 1;
    end else if (~sa1_mode) begin
        bw_w_seen <= sv_req;
        bw_r_seen <= sv_rreq;
        bw_we_b <= 0;
    end
end

bwram_256k bwram (
    .clk(mclk),
    .addr_a(BSRAM_ADDR[17:0]), .din_a(BSRAM_D), .q_a(bwram_q_a),
    .we_a(sa1_mode & ~BSRAM_WE_N),
    .addr_b(bw_addr_b), .din_b(bw_din_b), .q_b(bwram_q_b), .we_b(bw_we_b)
);
assign bw_sv_ack  = bw_ack_r;
assign bw_sv_rack = bw_rack_r;
assign bw_sv_q    = bw_q_r;
`else
assign bw_sv_ack  = 1'b0;
assign bw_sv_rack = 1'b0;
assign bw_sv_q    = 8'h0;
assign bwram_q_a  = 8'h0;
assign sa1_rom_q  = 16'h0;
assign sa1_rom_wait = 1'b0;
assign sa1_cpu2_addr = 22'h0;
assign sa1_cpu2_req  = 1'b0;
`endif

// ---- CX4: own ROM word cache on the same CPU2 lane --------------------------
// While the CX4 owns the ROM bus (cache fill, DMA source read, external ROM
// read) its byte address is on ROM_ADDR; the cache fetches each new word once
// over CPU2 and the CX4's wait counters hold until the word is valid. The
// S-CPU lane keeps serving WRAM (and S-CPU ROM reads while the CX4 is idle)
// exactly as before, so the two streams can no longer cancel each other.
// The cache module is shared with the SA-1 (a second instance): the access
// pattern is the same (mostly sequential words, second byte hits), and the
// two chips never share a cartridge, so the lane is muxed by chip type above.
`ifdef CHIP_CX4
// QUALIFY_WAIT: the CX4 moves its fetch address on most mclk edges, so the
// cache's registered hit would otherwise describe the previous word when
// the wait counter matches (wrong byte at WS1 = 0). The SA-1 instance above
// keeps the default and is unchanged.
sa1_rom_cache #(.QUALIFY_WAIT(1)) cx4_rom_cache (
    .mclk(mclk), .resetn(resetn), .active(cx4_mode & ~loading),
    .rom_addr(rom_addr), .rom_req(cx4_rom_req),
    .rom_q(cx4_rom_q), .rom_wait(cx4_rom_wait),
    .cpu2_addr(cx4_cpu2_addr), .cpu2_req(cx4_cpu2_req),
    .cpu2_req_ack(cpu2_req_ack), .cpu2_dout(cpu2_dout)
);
`else
assign cx4_rom_q = 16'h0;
assign cx4_rom_wait = 1'b0;
assign cx4_cpu2_addr = 22'h0;
assign cx4_cpu2_req = 1'b0;
`endif

localparam RV_IDLE_REQ0 = 3'd0;
localparam RV_WAIT0_REQ1 = 3'd1;
localparam RV_DATA0 = 3'd2;
localparam RV_WAIT1 = 3'd3;
localparam RV_DATA1 = 3'd4;
reg [2:0]   rvst;

wire        rv_valid;
reg         rv_ready;
wire [22:0] rv_addr;
wire [31:0] rv_wdata;
wire [3:0]  rv_wstrb;
reg  [15:0] rv_dout0;
wire [31:0] rv_rdata = {rv_dout, rv_dout0};
reg         rv_valid_r;
reg         rv_word;           // which word
reg         rv_req;
wire        rv_req_ack;
wire [15:0] rv_dout;
reg [1:0]   rv_ds;
reg         rv_new_req;

reg [14:0] vram1_addr_sd, vram2_addr_sd;
reg vram1_we_n_old, vram2_we_n_old;
reg vram1_req /* synthesis syn_keep=1 */; 
reg vram2_req /* synthesis syn_keep=1 */;
reg [7:0] vram1_din, vram2_din;

always @(posedge mclk) begin
    vram1_we_n_old <= VRAM1_WE_N;
    if ((~VRAM1_WE_N & vram1_we_n_old) || (VRAM1_ADDR[14:0] != vram1_addr_sd && ~VRAM_OE_N)) begin
        vram1_addr_sd <= VRAM1_ADDR[14:0];
        vram1_din <= VRAM1_D;
        vram1_req <= ~vram1_req;
    end

    vram2_we_n_old <= VRAM2_WE_N;
    if ((~VRAM2_WE_N & vram2_we_n_old) || (VRAM2_ADDR[14:0] != vram2_addr_sd && ~VRAM_OE_N)) begin
        vram2_addr_sd <= VRAM2_ADDR[14:0];
        vram2_din <= VRAM2_D;
        vram2_req <= ~vram2_req;
    end
end

sdram_snes sdram(
    .clk(fclk), .mclk(mclk), .clkref(DOT_CLK_CE), .resetn(resetn), .busy(sdram_busy),

    // SDRAM pins
    .SDRAM_DQ(IO_sdram_dq), .SDRAM_A(O_sdram_addr), .SDRAM_BA(O_sdram_ba), 
    .SDRAM_nCS(O_sdram_cs_n), .SDRAM_nWE(O_sdram_wen_n), .SDRAM_nRAS(O_sdram_ras_n), 
    .SDRAM_nCAS(O_sdram_cas_n), .SDRAM_CKE(O_sdram_cke), .SDRAM_DQM(O_sdram_dqm), 

    // CPU accesses
    .cpu_addr(cpu_addr[22:1]), .cpu_din(cpu_din), .cpu_port(cpu_port), 
    .cpu_port0(cpu_port0), .cpu_port1(cpu_port1), .cpu_req(cpu_req), .cpu_req_ack(),
    .cpu_we(cpu_we), .cpu_ds(cpu_ds),

`ifndef SDRAM_3CH
    // Second ROM reader
    .cpu2_addr(cpu2_addr), .cpu2_dout(cpu2_dout), .cpu2_req(cpu2_req), .cpu2_req_ack(cpu2_req_ack),
`endif

    // BSRAM accesses: SNES cartridge bus and save channel, via the bridge above
    .bsram_addr({3'b0, bs_addr_r}), .bsram_dout(bsram_dout), .bsram_din(bs_din_r),
    .bsram_req(bs_req_tog), .bsram_req_ack(bs_req_ack), .bsram_we(bs_we_r),

    // ARAM accesses
    .aram_16(aram_16), .aram_addr(aram_addr_sd), .aram_din(aram_din_sd), 
    .aram_dout(aram_dout), .aram_req(aram_req), .aram_req_ack(), .aram_we(aram_we_sd),

`ifdef SDRAM_3CH
    // VRAM accesses
    .vram1_addr(vram1_addr_sd), .vram1_req(vram1_req), .vram1_ack(), 
    .vram1_we(~vram1_we_n_old), .vram1_din(vram1_din), .vram1_dout(VRAM1_Q), 
    .vram2_addr(vram2_addr_sd), .vram2_req(vram2_req), .vram2_ack(),
    .vram2_we(~vram2_we_n_old),  .vram2_din(vram2_din), .vram2_dout(VRAM2_Q),
`endif

`ifdef MCU_BL616
    .rv_addr(), .rv_din(), 
    .rv_ds(), .rv_dout(), .rv_req(), .rv_req_ack(), .rv_we()
`else
    // IOSys risc-v softcore
    .rv_addr({rv_addr[22:2], rv_word}), .rv_din(rv_word ? rv_wdata[31:16] : rv_wdata[15:0]), 
    .rv_ds(rv_ds), .rv_dout(rv_dout), .rv_req(rv_req), .rv_req_ack(rv_req_ack), .rv_we(rv_wstrb != 0)
`endif
);

`ifndef SDRAM_3CH
// FPGA block RAM for SNES VRAM 
vram vram(
    .clk(mclk), 
    .vram1_addr(vram1_addr_sd), .vram1_req(vram1_req), .vram1_ack(), 
    .vram1_we(~vram1_we_n_old), .vram1_din(vram1_din), .vram1_dout(VRAM1_Q), 
    .vram2_addr(vram2_addr_sd), .vram2_req(vram2_req), .vram2_ack(),
    .vram2_we(~vram2_we_n_old),  .vram2_din(vram2_din), .vram2_dout(VRAM2_Q)
);
`endif

// Parse 64-byte rom header into rom_type and etc
smc_parser smc (
    .clk(mclk), .resetn(resetn & ~(loading & ~loading_r)),
    .rom_d(loader_do), .rom_strb(loader_do_valid), 
    .rom_type(rom_type), .rom_mask(rom_mask), .ram_mask(ram_mask),
    .rom_size(rom_size), .ram_size(ram_size),
    .header_finished(header_finished)
);

reg [7:0] loader_do_r;
reg loading_r;
always @(posedge mclk) begin
    if (~resetn) begin
        loading_r <= 0;
        loaded <= 0;
    end else begin
        loading_r <= loading;
        if (loader_do_valid && header_finished) begin
            loader_addr <= loader_addr + 23'd1; 
            loader_do_r <= loader_do;
        end
        if (loading & ~loading_r) begin
            loader_addr <= 0;
            loaded <= 0;
        end
        if (~loading & loading_r)
            loaded <= 1;
    end
end

`ifndef VERILATOR

// Controller input
`ifdef CONTROLLER_SNES
controller_snes joy1_snes (
    .clk(mclk), .resetn(resetn), .buttons(joy1_btns_snes),
    .joy_strb(joy1_strb), .joy_clk(joy1_clk), .joy_data(joy1_data)
);
controller_snes joy2_snes (
    .clk(mclk), .resetn(resetn), .buttons(joy2_btns_snes),
    .joy_strb(joy2_strb), .joy_clk(joy2_clk), .joy_data(joy2_data)
);
`else
assign joy1_btns_snes = 12'h0;
assign joy2_btns_snes = 12'h0;
`endif

`ifdef CONTROLLER_DS2
controller_ds2 joy1_ds2 (
    .clk(mclk), .snes_buttons(joy1_btns_ds2),
    .ds_clk(ds_clk), .ds_miso(ds_miso), .ds_mosi(ds_mosi), .ds_cs(ds_cs) 
);
controller_ds2 joy2_ds2 (
   .clk(mclk), .snes_buttons(joy2_btns_ds2),
   .ds_clk(ds_clk2), .ds_miso(ds_miso2), .ds_mosi(ds_mosi2), .ds_cs(ds_cs2) 
);
`else
assign joy1_btns_ds2 = 12'h0;
assign joy2_btns_ds2 = 12'h0;
`endif

`ifdef USB1
wire clk12;
wire pll_lock_12;
wire usb_conerr;
wire [1:0] usb_type;
pll_12 pll12(.clkin(sys_clk), .clkout0(clk12), .lock(pll_lock_12));
usb_hid_host usb_hid_host (
    .usbclk(clk12), .usbrst_n(pll_lock_12),
    .usb_dm(usb1_dn), .usb_dp(usb1_dp),
    .typ(usb_type), .conerr(usb_conerr),
    .game_snes(joy1_usb)
);
`else
assign joy1_usb = 12'h0;
`endif

`ifdef USB2
wire usb_conerr2;
wire [1:0] usb_type2;   
usb_hid_host usb_hid_host2 (
    .usbclk(clk12), .usbrst_n(pll_lock_12),
    .usb_dm(usb2_dn), .usb_dp(usb2_dp),
    .game_snes(joy2_usb), .typ(usb_type2), .conerr(usb_conerr2)
);
assign led = ~{joy2_usb[1:0], usb_type2, usb_conerr2, usb_type, usb_conerr};
`else
assign joy2_usb = 12'h0;
`endif

// output button presses to SNES
controller_adapter joy1_adapter (
    .clk(mclk), .snes_joy_strb(snes_joy_strb), 
    .snes_buttons(joy1_btns_ds2 | joy1_btns_snes | hid1 | joy1_usb), .snes_joy_clk(snes_joy1_clk), .snes_joy_di(snes_joy1_di[0])
);
controller_adapter joy2_adapter (
    .clk(mclk), .snes_joy_strb(snes_joy_strb), 
    .snes_buttons(joy2_btns_ds2 | joy2_btns_snes | hid2 | joy2_usb), .snes_joy_clk(snes_joy2_clk), .snes_joy_di(snes_joy2_di[0])
);
assign snes_joy1_di[1] = 0;  // P3
assign snes_joy2_di[1] = 0;  // P4

wire [14:0] overlay_color;
wire [7:0] overlay_x;
wire [7:0] overlay_y;

wire [7:0] dbg_dat_out_loader;

snes2hdmi s2h(
    .clk(mclk), .resetn(resetn), .snes_refresh(refresh),
    .pause_snes_for_frame_sync(pause_snes_for_frame_sync),
    .dotclk(dotclk), .hblank(~hblankn),.vblank(~vblankn),.rgb5(rgb_out),
    .xs(x_out), .ys(y_out), .hires(hires),
    .overlay(overlay), .overlay_x(overlay_x), .overlay_y(overlay_y),
    .overlay_color(overlay_color), 
    .scanlines(core_config[16]), .sl_darkness(core_config[19:18]), .sl_thick(core_config[20]), .sl_out(core_config[21]),
    .video_config(video_config),
    .audio_l(audio_l), .audio_r(audio_r), .audio_ready(audio_ready), .audio_en(audio_en),
    .pause(pause),
    .std_timing(video_std_timing),
    .clk_pixel(hclk),.clk_5x_pixel(hclk5),.locked(1'b1),
    .tmds_clk_n(tmds_clk_n), .tmds_clk_p(tmds_clk_p),
    .tmds_d_n(tmds_d_n), .tmds_d_p(tmds_d_p)
);

iosys_bl616 #(.CORE_ID(2), .FREQ(21_484_000), .SAVE_IF(1), .SAVE_AW(SAVE_AW), .SAVE_RDY(1)) iosys (
    .clk(mclk), .hclk(hclk), .resetn(resetn),
    .overlay(overlay), .overlay_x(overlay_x), .overlay_y(overlay_y),
    .overlay_color(overlay_color),
    .core_config(core_config), .video_config(video_config),
    .time_unix(time_unix), .time_bcd(time_bcd),
    .time_solar(time_solar), .time_flags(time_flags), .time_strobe(time_strobe),
    .joy1(joy1_btns_ds2 | joy1_btns_snes | joy1_usb), .joy2(joy2_btns_ds2 | joy2_btns_snes | joy2_usb), .hid1(hid1), .hid2(hid2),
    .uart_tx(UART_TXD), .uart_rx(UART_RXD),
    .rom_loading(loading), .rom_do(loader_do), .rom_do_valid(loader_do_valid),
    .sv_addr(sv_addr), .sv_din(sv_din), .sv_we(), .sv_req(sv_req), .sv_ack(sv_ack),
    .sv_rreq(sv_rreq), .sv_rack(sv_rack), .sv_q(sv_q), .sv_core_we(sv_core_we)
);

`else       // VERILATOR

// test loader with embedded rom
test_loader test_loader (
    .clk(mclk), .resetn(resetn),
    .dout(loader_do), .dout_valid(loader_do_valid),
    .loading(loading), .fail()
);

// test audio sink: FIFO-like rate limiting to sound sample generation
reg [3:0] sample_counter = 0;
always @(posedge mclk) begin
    if (audio_ready)
        sample_counter <= 0;
    else
        sample_counter <= sample_counter == 15 ? 15 : sample_counter + 1;
end
assign audio_en = sample_counter == 15;


// test video sync by turning on pause_snes_for_frame_sync periodically
reg test_halt_snes, test_sync_done;
reg [3:0] test_halt_cnt = 0;
assign pause_snes_for_frame_sync = test_halt_snes;

always @(posedge mclk) begin    // halt SNES during snes dram refresh on line 2
    if (~resetn) begin
        test_halt_cnt <= 0;
        test_halt_snes <= 0;
        test_sync_done <= 0;
    end else begin
        if (~test_sync_done) begin
            if (~test_halt_snes) begin
                if (y_out[7:0] == 2 && refresh) begin
                    test_halt_snes <= 1;
                    test_halt_cnt <= 4'd12;        // halt snes for 13 cycles
                end
            end else begin
                if (test_halt_cnt != 0) begin
                    test_halt_cnt <= test_halt_cnt - 4'd1;
                end else begin
                    test_halt_snes <= 0;
                    test_sync_done <= 1;
                end                            
            end
        end else if (y_out[7:0] == 8'd200)
            test_sync_done <= 0;
    end
end

`endif

`ifndef VERILATOR

reg [19:0] timer;           // 21 times per second

// status display on LED

reg [9:0] status;
//assign led = s0 == 1'b0 ? ~status[9:5] : ~status[4:0];        // s0==0 when pressed, for mega138k
// assign led = UART_TXD;
//assign led = joy1_btns[1:0];        // Y and B

always @(posedge mclk) begin
    if (loading && ~loading_r)
        status <= 0;
    if (loaded) begin
        case (rom_addr)
        23'h00_000A: status[1] <= 1;
        23'h00_00A1: status[2] <= 1;        // Clear_WRAM
        23'h00_0645: status[3] <= 1;        // Main
        23'h00_0111: status[4] <= 1;        // DMA_Palette
        
        23'h00_06AB: status[5] <= 1;        // Draw_Map
        23'h00_072A: status[6] <= 1;        // Init_Music
        23'h00_075F: status[7] <= 1;        // Infinite_loop
        23'h00_0787: status[8] <= 1;        // left button
        default: ;
        endcase
    end
end

`endif

endmodule

