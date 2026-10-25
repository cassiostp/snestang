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
wire fclk_p;                    // SDRAM clock, 207.581 degrees (8.9375 ns) behind fclk
wire clk27;                     // 27Mhz for hdmi clock generation
wire hclk5, hclk;               // pixel clock and 5x high-speed: 74.25/371.25 MHz standard, 54/270 MHz in the hz120 variant

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
`ifdef SNES_SAVESTATE
wire ss_freeze, ss_reset, ss_loaded, ss_active, ss_edge_reset;
wire [12:0] ss_a;
wire [7:0] ss_d, ss_regs_q, ss_sd_regs_q, ss_vr_regs_q;
wire ss_we, ss_point;
wire [2:0] ss_op;
wire ss_op_stb;
wire [127:0] ss_status;
wire [19:0] ss_img_raddr, ss_img_waddr;
wire [7:0] ss_img_q, ss_img_wdin;
wire ss_img_rd_stb, ss_img_taken, ss_img_abort, ss_img_rdy, ss_img_wr_stb;
wire [24:0] ss_mem_addr;
wire [7:0] ss_mem_din, ss_sd_q, ss_vr_q;
wire ss_mem_we, ss_mem_req, ss_sd_ack, ss_vr_ack, ss_phase;
wire ss_vram_sel = ss_mem_addr[24:16] == 9'h180;
wire ss_mem_ack = ss_vram_sel ? ss_vr_ack : ss_sd_ack;
wire [7:0] ss_mem_q = ss_vram_sel ? ss_vr_q : ss_sd_q;
reg [5:0] ss_drain = 0;
always @(posedge mclk) ss_drain <= ss_freeze ? (ss_drain == 63 ? 63 : ss_drain + 1'b1) : 0;
wire ss_block = ss_freeze && ss_drain >= 8;
wire ss_waiting = ss_active && !ss_freeze;
`endif
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
    .clkoutp(fclk_p),           // 207.581 degrees behind fclk
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
// ROM_ADDR[0], since CX4/LoROM fetches are byte-wide). While the CX4 or the
// GSU owns the ROM bus its own fetches come from the CPU2 lane through the
// word caches below instead, so a coinciding S-CPU WRAM request can no
// longer cancel the ROM fetch (and the chip waits for the word anyway).
wire [15:0] ROM_Q;
wire [15:0] rom_word_cpu2;
wire        cx4_owns_rom;
wire        gsu_owns_rom;
wire [15:0] rom_word = (cx4_owns_rom || gsu_owns_rom) ? rom_word_cpu2 : cpu_port0;
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
// GSU: its own ROM fetches ride the same CPU2 lane while it owns the ROM
// bus (RON), like the CX4's. The three chips never share a cartridge
// (rom_type 6 vs 4 vs 7), so the caches mux the one lane.
wire        gsu_rom_req;
wire [15:0] gsu_rom_q;
wire        gsu_rom_wait;
wire        gsu_ram_req;
wire        gsu_ram_wait;
`ifdef CHIP_GSU
wire        gsu_mode = rom_type[7:4] == 4'h7;
`else
wire        gsu_mode = 1'b0;
`endif
assign      gsu_owns_rom = gsu_mode & gsu_rom_req;
assign      rom_word_cpu2 = cx4_owns_rom ? cx4_rom_q :
                            gsu_owns_rom ? gsu_rom_q : sa1_rom_q;
wire  [7:0] bwram_q_a;             // SA-1 BW-RAM (block RAM) read data
wire [23:0] gsu_ram_mask;
wire  [7:0] BSRAM_Q;
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

// Selects the standard HDMI timing (for displays that refuse the native
// rate; a menu option for it may come later). Tied 0: the game runs at the
// console's own refresh rate (60 Hz builds) or twice it (the hz120 variant).
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
`ifdef SNES_SAVESTATE
    if (~sdram_busy && ~pause_snes_for_frame_sync && (~pause || ss_waiting) && loaded)
`else
    if (~sdram_busy && ~pause_snes_for_frame_sync && ~pause && loaded)
`endif
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
`ifdef SNES_SAVESTATE
    .ss_hold(ss_freeze), .ss_a(ss_a), .ss_d(ss_d), .ss_we(ss_we), .ss_q(ss_regs_q), .ss_point(ss_point),
`endif
    .MCLK(mclk), .RESET_N(
`ifdef SNES_SAVESTATE
    resetn & ~loading & ~ss_reset
`else
    resetn & ~loading
`endif
), .ENABLE(enable),
    .SYSCLKF_CE(sysclkf_ce), .SYSCLKR_CE(sysclkr_ce), .REFRESH(refresh),

    .ROM_TYPE(rom_type), .ROM_MASK(rom_mask), .RAM_MASK(gsu_mode ? gsu_ram_mask : ram_mask),

    .ROM_ADDR(ROM_ADDR), .ROM_D(ROM_D), .ROM_Q(ROM_Q),
    .ROM_CE_N(ROM_CE_N), .ROM_OE_N(ROM_OE_N), .ROM_WE_N(ROM_WE_N),
    .ROM_WORD(ROM_WORD),

    .SA1_ROM_ADDR(sa1_rom_addr), .SA1_ROM_REQ(sa1_rom_req),
    .SA1_ROM_Q(sa1_rom_q), .SA1_ROM_WAIT(sa1_rom_wait),

    .CX4_ROM_REQ(cx4_rom_req), .CX4_ROM_WAIT(cx4_rom_wait),
    .GSU_ROM_REQ(gsu_rom_req), .GSU_ROM_WAIT(gsu_rom_wait),
    .GSU_RAM_REQ(gsu_ram_req), .GSU_RAM_WAIT(gsu_ram_wait),

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

    .BLEND(BLEND), .PAL(PAL), .HIGH_RES(hires), .FIELD(), .INTERLACE(), .DIS_SHORTLINE(1'b0),
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
wire [22:1] sa1_cpu2_addr, cx4_cpu2_addr, gsu_cpu2_addr, cpu2_addr;
wire        sa1_cpu2_req, cx4_cpu2_req, gsu_cpu2_req, cpu2_req;
assign      cpu2_addr = sa1_mode ? sa1_cpu2_addr :
                        gsu_mode ? gsu_cpu2_addr : cx4_cpu2_addr;
assign      cpu2_req  = sa1_mode ? sa1_cpu2_req  :
                        gsu_mode ? gsu_cpu2_req  : cx4_cpu2_req;
wire        cpu2_req_ack;
wire [15:0] cpu2_dout;

reg [16:0]  wram_addr_sd;
reg         wram_wr_r, wram_rd_r;

reg [19:0]  bsram_addr;             // last cartridge-bus BSRAM address queued
wire        gsu_ram_bus = gsu_mode & gsu_ram_req;				// GSU owns the RAM bus right now
// GSU writes must not also queue a read. Other mappers keep their original
// read detection, including OBC-1's accesses outside S-CPU read cycles.
wire        bsram_rd = ~BSRAM_CE_N & (~BSRAM_RD_N ||
                       (gsu_mode ? (gsu_ram_bus & BSRAM_WE_N) : rom_type[7:4] == 4'hC));
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
`ifdef SNES_SAVESTATE
    if (ss_we) begin
      case (ss_a)
        13'h1b60: cpu_port <= ss_d[0:0];
        13'h1b61: cpu_req <= ss_d[0:0];
        13'h1b62: cpu_ds[1:0] <= ss_d[1:0];
        13'h1b63: cpu_din[7:0] <= ss_d[7:0];
        13'h1b64: cpu_din[15:8] <= ss_d[7:0];
        13'h1b65: cpu_addr[7:0] <= ss_d[7:0];
        13'h1b66: cpu_addr[15:8] <= ss_d[7:0];
        13'h1b67: cpu_addr[22:16] <= ss_d[6:0];
        13'h1b68: cpu_we <= ss_d[0:0];
        13'h1b69: rom_addr_sd[7:0] <= ss_d[7:0];
        13'h1b6a: rom_addr_sd[15:8] <= ss_d[7:0];
        13'h1b6b: rom_addr_sd[22:16] <= ss_d[6:0];
        13'h1b6c: wram_addr_sd[7:0] <= ss_d[7:0];
        13'h1b6d: wram_addr_sd[15:8] <= ss_d[7:0];
        13'h1b6e: wram_addr_sd[16:16] <= ss_d[0:0];
        13'h1b6f: wram_wr_r <= ss_d[0:0];
        13'h1b70: wram_rd_r <= ss_d[0:0];
        13'h1b74: bsram_rd_r <= ss_d[0:0];
        13'h1b75: bsram_wr_r <= ss_d[0:0];
        13'h1b76: aram_addr_sd[7:0] <= ss_d[7:0];
        13'h1b77: aram_addr_sd[15:8] <= ss_d[7:0];
        13'h1b78: aram_din_sd[7:0] <= ss_d[7:0];
        13'h1b79: aram_din_sd[15:8] <= ss_d[7:0];
        13'h1b7a: aram_we_sd <= ss_d[0:0];
        13'h1b7b: aram_rd_r <= ss_d[0:0];
        13'h1b7c: aram_wr_r <= ss_d[0:0];
        13'h1b7d: aram_req <= ss_d[0:0];
        default: ;
      endcase
    end else if (!ss_freeze) begin
`endif

    if (~resetn) begin
    end else begin
        
        // ROM read and load. While the CX4 owns the ROM bus its fetch address
        // is on ROM_ADDR: the CPU lane skips it (the CX4 reads the same word
        // through the CPU2 cache instead), so a coinciding S-CPU WRAM request
        // can no longer cancel the ROM fetch. S-CPU ROM reads while the CX4
        // is idle still use this lane exactly as before.
        if (loading && loader_do_valid && header_finished && loader_addr[0]
            || ~loading && ~ROM_CE_N && rom_addr_sd != rom_addr && ~cx4_owns_rom && ~gsu_owns_rom) begin
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

        // BSRAM read/write. The save-RAM bridge below serializes these with
        // the save channel's accesses; bs_det_new (in the bridge) marks a
        // new access from these edge registers and queues it there.
        bsram_rd_r <= bsram_rd; bsram_wr_r <= bsram_wr;

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

`ifdef SNES_SAVESTATE
    end
`endif
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
// edge detector above queues each new cartridge access in the 16-deep FIFO
// below (a single pending slot was overwritten when the GSU issued byte
// writes ~4 mclk apart against a ~6+ mclk service time: the first byte of
// each stw pair was lost; and every write also queued a phantom read, so
// bulk transfers overran even the 4-deep FIFO and lost bytes); the save channel toggles sv_req (write) /
// sv_rreq (read). This arbiter owns the
// controller's req/ack pair and serves one byte at a time, SNES first: save
// accesses only slip into idle slots, so the SNES never queues behind one,
// while a SNES access arriving mid-save-byte waits ~6 clocks -- the SNES
// cartridge window is many times that. The controller toggles bs_req_ack once
// per access (fclk domain, like the existing cpu/aram handshakes); it is
// synchronized here and routed back to whichever source was served. Reads
// capture the controller's sticky bsram_dout before the next access can
// overwrite it, since the arbiter keeps the port until the byte is banked.
// 16-deep write queue built from explicit per-stage registers (not arrays:
// Gowin maps arrays to BSRAM even with an async read side, and the hz 120
// frame buffer needs those blocks). GSU mirrored reads bypass the queue;
// other accesses retain the SDRAM path and its original four-entry limit.
genvar bs_fi;
generate for (bs_fi = 0; bs_fi < 16; bs_fi = bs_fi + 1) begin : BS_FIFO
    reg [16:0] addr = 17'h0;
    reg  [7:0] din = 8'h0;
    reg        we = 1'b0;
end endgenerate
reg   [4:0] bs_fifo_wptr = 0, bs_fifo_rptr = 0;
wire        bs_fifo_empty = bs_fifo_wptr == bs_fifo_rptr;
wire        bs_fifo_full  = bs_fifo_wptr == bs_fifo_rptr + (gsu_mode ? 5'd16 : 5'd4);
// Only the low 64 KiB of GSU RAM is mirrored. All non-GSU cartridges and
// the upper 64 KiB retain the SDRAM read and save-data shadow path.
wire        bs_mirror_sel = gsu_mode && !BSRAM_ADDR[16];
wire        bs_det_new = (bsram_rd && BSRAM_ADDR != bsram_addr) ||
                         (bsram_wr & ~bsram_wr_r) || (bsram_rd & ~bsram_rd_r);
// Mirrored reads need no SDRAM transaction; writes still go through the
// queue for save-channel coherence. Unmirrored accesses keep the detector.
wire        bs_push = (bs_mirror_sel ? (bsram_wr & ~bsram_wr_r) : bs_det_new)
                      && ~bs_fifo_full && ~sa1_mode;
reg [16:0] bs_issue_addr;
reg  [7:0] bs_issue_din;
reg        bs_issue_we;
always @* begin
    bs_issue_addr = BS_FIFO[0].addr;
    bs_issue_din = BS_FIFO[0].din;
    bs_issue_we = BS_FIFO[0].we;
    case (bs_fifo_rptr[3:0])
        4'd0: begin bs_issue_addr = BS_FIFO[0].addr; bs_issue_din = BS_FIFO[0].din; bs_issue_we = BS_FIFO[0].we; end
        4'd1: begin bs_issue_addr = BS_FIFO[1].addr; bs_issue_din = BS_FIFO[1].din; bs_issue_we = BS_FIFO[1].we; end
        4'd2: begin bs_issue_addr = BS_FIFO[2].addr; bs_issue_din = BS_FIFO[2].din; bs_issue_we = BS_FIFO[2].we; end
        4'd3: begin bs_issue_addr = BS_FIFO[3].addr; bs_issue_din = BS_FIFO[3].din; bs_issue_we = BS_FIFO[3].we; end
        4'd4: begin bs_issue_addr = BS_FIFO[4].addr; bs_issue_din = BS_FIFO[4].din; bs_issue_we = BS_FIFO[4].we; end
        4'd5: begin bs_issue_addr = BS_FIFO[5].addr; bs_issue_din = BS_FIFO[5].din; bs_issue_we = BS_FIFO[5].we; end
        4'd6: begin bs_issue_addr = BS_FIFO[6].addr; bs_issue_din = BS_FIFO[6].din; bs_issue_we = BS_FIFO[6].we; end
        4'd7: begin bs_issue_addr = BS_FIFO[7].addr; bs_issue_din = BS_FIFO[7].din; bs_issue_we = BS_FIFO[7].we; end
        4'd8: begin bs_issue_addr = BS_FIFO[8].addr; bs_issue_din = BS_FIFO[8].din; bs_issue_we = BS_FIFO[8].we; end
        4'd9: begin bs_issue_addr = BS_FIFO[9].addr; bs_issue_din = BS_FIFO[9].din; bs_issue_we = BS_FIFO[9].we; end
        4'd10: begin bs_issue_addr = BS_FIFO[10].addr; bs_issue_din = BS_FIFO[10].din; bs_issue_we = BS_FIFO[10].we; end
        4'd11: begin bs_issue_addr = BS_FIFO[11].addr; bs_issue_din = BS_FIFO[11].din; bs_issue_we = BS_FIFO[11].we; end
        4'd12: begin bs_issue_addr = BS_FIFO[12].addr; bs_issue_din = BS_FIFO[12].din; bs_issue_we = BS_FIFO[12].we; end
        4'd13: begin bs_issue_addr = BS_FIFO[13].addr; bs_issue_din = BS_FIFO[13].din; bs_issue_we = BS_FIFO[13].we; end
        4'd14: begin bs_issue_addr = BS_FIFO[14].addr; bs_issue_din = BS_FIFO[14].din; bs_issue_we = BS_FIFO[14].we; end
        4'd15: begin bs_issue_addr = BS_FIFO[15].addr; bs_issue_din = BS_FIFO[15].din; bs_issue_we = BS_FIFO[15].we; end
    default: begin end
    endcase
end
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
wire        snes_bs_new = ~bs_fifo_empty;
wire        sv_w_new    = sv_req != sv_w_seen;
wire        sv_r_new    = sv_rreq != sv_r_seen;
wire        bs_free     = bs_req_tog == bs_ack;
wire        bs_issue_ok = ~bs_busy | bs_free;   // idle, or acked this very clock
// A GSU cartridge push reserves the mirror's single write port. Queue it
// first, then issue a pending restore after the cartridge FIFO drains.
// The save channel shares the controller's one BSRAM port with the S-CPU,
// which samples BSRAM_Q at its fixed bus-cycle edge with no wait. A
// save-channel byte issued while the core runs can still be in flight when
// the S-CPU presents its read; the queued S-CPU byte then misses its sample
// edge and reads the in-flight byte (issue #65). So the bridge only starts
// save-channel bytes while the core cannot present one (enable low: the
// firmware pauses the core for dumps and restores before release). A pending
// save toggle simply waits for the pause; the S-CPU path is untouched and
// gains no wait states, and GSU wait / SA-1 BW-RAM behaviour is unchanged.
wire        bs_save_allow = ~enable;
wire        bs_sv_w_issue = bs_issue_ok && sv_w_new && !sa1_mode &&
                            !(gsu_mode && bs_push) && bs_save_allow;

always @(posedge mclk) begin
`ifdef SNES_SAVESTATE
    if (ss_we) begin
      case (ss_a)
        13'h1b71: bsram_addr[7:0] <= ss_d[7:0];
        13'h1b72: bsram_addr[15:8] <= ss_d[7:0];
        13'h1b73: bsram_addr[19:16] <= ss_d[3:0];
        13'h1b88: bs_req_tog <= ss_d[0:0];
        13'h1b89: bs_ack_sync[2:0] <= ss_d[2:0];
        13'h1b8a: bs_busy <= ss_d[0:0];
        13'h1b8b: bs_owner <= ss_d[0:0];
        13'h1b8c: bs_we_r <= ss_d[0:0];
        13'h1b8d: bs_addr_r[7:0] <= ss_d[7:0];
        13'h1b8e: bs_addr_r[15:8] <= ss_d[7:0];
        13'h1b8f: bs_addr_r[16:16] <= ss_d[0:0];
        13'h1b90: bs_din_r[7:0] <= ss_d[7:0];
        13'h1b91: snes_bsram_hold[7:0] <= ss_d[7:0];
        13'h1b92: snes_bsram_shadow <= ss_d[0:0];
        default: ;
      endcase
    end else if (!ss_freeze) begin
`endif

    bs_ack_sync <= {bs_ack_sync[1:0], bs_req_ack};
    if (sa1_mode) begin                 // the BW-RAM block RAM serves both sides
        bs_fifo_rptr <= bs_fifo_wptr;   // drop any queued cartridge access
        sv_w_seen <= sv_req;
        sv_r_seen <= sv_rreq;
    end
    if (bs_det_new)
        bsram_addr <= BSRAM_ADDR;
    if (bs_push) begin
        case (bs_fifo_wptr[3:0])
        4'd0: begin BS_FIFO[0].addr <= BSRAM_ADDR[16:0]; BS_FIFO[0].din <= BSRAM_D; BS_FIFO[0].we <= bsram_wr; end
        4'd1: begin BS_FIFO[1].addr <= BSRAM_ADDR[16:0]; BS_FIFO[1].din <= BSRAM_D; BS_FIFO[1].we <= bsram_wr; end
        4'd2: begin BS_FIFO[2].addr <= BSRAM_ADDR[16:0]; BS_FIFO[2].din <= BSRAM_D; BS_FIFO[2].we <= bsram_wr; end
        4'd3: begin BS_FIFO[3].addr <= BSRAM_ADDR[16:0]; BS_FIFO[3].din <= BSRAM_D; BS_FIFO[3].we <= bsram_wr; end
        4'd4: begin BS_FIFO[4].addr <= BSRAM_ADDR[16:0]; BS_FIFO[4].din <= BSRAM_D; BS_FIFO[4].we <= bsram_wr; end
        4'd5: begin BS_FIFO[5].addr <= BSRAM_ADDR[16:0]; BS_FIFO[5].din <= BSRAM_D; BS_FIFO[5].we <= bsram_wr; end
        4'd6: begin BS_FIFO[6].addr <= BSRAM_ADDR[16:0]; BS_FIFO[6].din <= BSRAM_D; BS_FIFO[6].we <= bsram_wr; end
        4'd7: begin BS_FIFO[7].addr <= BSRAM_ADDR[16:0]; BS_FIFO[7].din <= BSRAM_D; BS_FIFO[7].we <= bsram_wr; end
        4'd8: begin BS_FIFO[8].addr <= BSRAM_ADDR[16:0]; BS_FIFO[8].din <= BSRAM_D; BS_FIFO[8].we <= bsram_wr; end
        4'd9: begin BS_FIFO[9].addr <= BSRAM_ADDR[16:0]; BS_FIFO[9].din <= BSRAM_D; BS_FIFO[9].we <= bsram_wr; end
        4'd10: begin BS_FIFO[10].addr <= BSRAM_ADDR[16:0]; BS_FIFO[10].din <= BSRAM_D; BS_FIFO[10].we <= bsram_wr; end
        4'd11: begin BS_FIFO[11].addr <= BSRAM_ADDR[16:0]; BS_FIFO[11].din <= BSRAM_D; BS_FIFO[11].we <= bsram_wr; end
        4'd12: begin BS_FIFO[12].addr <= BSRAM_ADDR[16:0]; BS_FIFO[12].din <= BSRAM_D; BS_FIFO[12].we <= bsram_wr; end
        4'd13: begin BS_FIFO[13].addr <= BSRAM_ADDR[16:0]; BS_FIFO[13].din <= BSRAM_D; BS_FIFO[13].we <= bsram_wr; end
        4'd14: begin BS_FIFO[14].addr <= BSRAM_ADDR[16:0]; BS_FIFO[14].din <= BSRAM_D; BS_FIFO[14].we <= bsram_wr; end
        4'd15: begin BS_FIFO[15].addr <= BSRAM_ADDR[16:0]; BS_FIFO[15].din <= BSRAM_D; BS_FIFO[15].we <= bsram_wr; end
        default: begin end
        endcase
        bs_fifo_wptr <= bs_fifo_wptr + 5'd1;
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
        bs_addr_r <= bs_issue_addr;
        bs_din_r  <= bs_issue_din;
        bs_we_r   <= bs_issue_we;
        bs_owner  <= 0;
        bs_busy   <= 1;
        bs_req_tog <= ~bs_req_tog;
        bs_fifo_rptr <= bs_fifo_rptr + 5'd1;
    end else if (bs_sv_w_issue) begin
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
    end else if (bs_issue_ok && sv_r_new && ~sa1_mode && bs_save_allow) begin
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

`ifdef SNES_SAVESTATE
    end
`endif
end
wire sv_core_we = bsram_wr & ~bsram_wr_r;       // the SNES wrote save RAM

// While the GSU owns the RAM bus, hold its RAM_ACCESS_CNT completions
// until the bridge has finished the byte it presented: nothing queued,
// nothing being detected this cycle, and no cartridge access in flight.
// (Save-channel bytes in flight do not count: they cannot be the GSU's,
// and the GSU's own queued byte keeps snes_bs_new up behind one.)
assign gsu_ram_wait = gsu_mode & gsu_ram_req &
                      (bs_det_new | snes_bs_new | (bs_busy & ~bs_owner));

// GSU read mirror: a one-cycle block-RAM read avoids stale
// S-CPU framebuffer uploads under SDRAM contention. Only GSU low-bank RAM
// is mirrored; larger windows fall back to SDRAM without address aliasing.
reg   [7:0] bs_mirror [0:65535];
reg   [7:0] bs_mirror_q = 8'hFF;
wire bs_mirror_save = gsu_mode && !snes_bs_new && bs_sv_w_issue && !sv_addr[16];
wire bs_mirror_write = bs_mirror_save || (bs_push && bsram_wr && bs_mirror_sel);
wire [15:0] bs_mirror_addr = bs_mirror_save ? sv_addr[15:0] : BSRAM_ADDR[15:0];
wire [7:0] bs_mirror_din = bs_mirror_save ? sv_din : BSRAM_D;
always @(posedge mclk) begin
    // A single address/write-enable template makes GW5A infer WRITE_MODE=0.
    if (bs_mirror_write)
        bs_mirror[bs_mirror_addr] <= bs_mirror_din;
    else
        bs_mirror_q <= bs_mirror[bs_mirror_addr];
end
`ifdef VERILATOR
// Match the local SDRAM model's initial fill. Hardware RAM is initialized
// by cartridge software or the save restore path before use.
initial begin
    integer i;
    for (i = 0; i < 65536; i = i + 1) bs_mirror[i] = 8'hFF;
end
`endif
assign BSRAM_Q = sa1_mode ? bwram_q_a : bs_mirror_sel ? bs_mirror_q :
                (snes_bsram_shadow ? snes_bsram_hold : bsram_dout);

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

// ---- GSU: own ROM word cache on the same CPU2 lane ---------------------------
// While the GSU owns the ROM bus (cache fill, R14 ROM load, opcode fetch
// outside the code cache) its byte address is on ROM_ADDR; the cache
// fetches each new word once over CPU2 and ROM_WAIT holds the GSU's
// ROM_ACCESS_CNT sample points until the word is valid. S-CPU ROM reads
// while the GSU is idle still use the CPU lane exactly as before.
// QUALIFY_WAIT for the same reason as the CX4 instance: in 21 MHz mode the
// GSU can move its fetch address on consecutive mclk edges, so the cache's
// registered hit must be qualified against the current address.
`ifdef CHIP_GSU
sa1_rom_cache #(.QUALIFY_WAIT(1)) gsu_rom_cache (
    .mclk(mclk), .resetn(resetn), .active(gsu_mode & ~loading),
    .rom_addr(rom_addr), .rom_req(gsu_rom_req),
    .rom_q(gsu_rom_q), .rom_wait(gsu_rom_wait),
    .cpu2_addr(gsu_cpu2_addr), .cpu2_req(gsu_cpu2_req),
    .cpu2_req_ack(cpu2_req_ack), .cpu2_dout(cpu2_dout)
);
`else
assign gsu_rom_q = 16'h0;
assign gsu_rom_wait = 1'b0;
assign gsu_cpu2_addr = 22'h0;
assign gsu_cpu2_req = 1'b0;
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
`ifdef SNES_SAVESTATE
    if (ss_we) begin
      case (ss_a)
        13'h1b7e: vram1_addr_sd[7:0] <= ss_d[7:0];
        13'h1b7f: vram1_addr_sd[14:8] <= ss_d[6:0];
        13'h1b80: vram2_addr_sd[7:0] <= ss_d[7:0];
        13'h1b81: vram2_addr_sd[14:8] <= ss_d[6:0];
        13'h1b82: vram1_we_n_old <= ss_d[0:0];
        13'h1b83: vram2_we_n_old <= ss_d[0:0];
        13'h1b84: vram1_req <= ss_d[0:0];
        13'h1b85: vram2_req <= ss_d[0:0];
        13'h1b86: vram1_din[7:0] <= ss_d[7:0];
        13'h1b87: vram2_din[7:0] <= ss_d[7:0];
        default: ;
      endcase
    end else if (!ss_freeze) begin
`endif

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

`ifdef SNES_SAVESTATE
    end
`endif
end

sdram_snes sdram(
`ifdef SNES_SAVESTATE
    .ss_addr(ss_mem_addr), .ss_din(ss_mem_din), .ss_req(ss_mem_req), .ss_we(ss_mem_we),
    .ss_ack(ss_sd_ack), .ss_q(ss_sd_q), .ss_block(ss_block),
    .ss_reg_a(ss_a), .ss_reg_d(ss_d), .ss_reg_we(ss_we), .ss_reg_q(ss_sd_regs_q), .ss_phase(ss_phase),
    .ss_cpu_port0(cpu_port0), .ss_cpu_port1(cpu_port1),
    .ss_aram_dout(aram_dout), .ss_bsram_dout(bsram_dout),
`endif
    .clk(fclk), .mclk(mclk), .clkref(DOT_CLK_CE), .resetn(resetn), .busy(sdram_busy),

    // SDRAM pins
    .SDRAM_DQ(IO_sdram_dq), .SDRAM_A(O_sdram_addr), .SDRAM_BA(O_sdram_ba), 
    .SDRAM_nCS(O_sdram_cs_n), .SDRAM_nWE(O_sdram_wen_n), .SDRAM_nRAS(O_sdram_ras_n), 
    .SDRAM_nCAS(O_sdram_cas_n), .SDRAM_CKE(O_sdram_cke), .SDRAM_DQM(O_sdram_dqm), 

    // CPU accesses
    .cpu_addr(cpu_addr[22:1]), .cpu_din(cpu_din), .cpu_port(cpu_port), 
`ifdef SNES_SAVESTATE
    .cpu_port0(), .cpu_port1(), .cpu_req(cpu_req), .cpu_req_ack(),
`else
    .cpu_port0(cpu_port0), .cpu_port1(cpu_port1), .cpu_req(cpu_req), .cpu_req_ack(),
`endif
    .cpu_we(cpu_we), .cpu_ds(cpu_ds),

`ifndef SDRAM_3CH
    // Second ROM reader
    .cpu2_addr(cpu2_addr), .cpu2_dout(cpu2_dout), .cpu2_req(cpu2_req), .cpu2_req_ack(cpu2_req_ack),
`endif

    // BSRAM accesses: SNES cartridge bus and save channel, via the bridge above
`ifdef SNES_SAVESTATE
    .bsram_addr({3'b0, bs_addr_r}), .bsram_dout(), .bsram_din(bs_din_r),
`else
    .bsram_addr({3'b0, bs_addr_r}), .bsram_dout(bsram_dout), .bsram_din(bs_din_r),
`endif
    .bsram_req(bs_req_tog), .bsram_req_ack(bs_req_ack), .bsram_we(bs_we_r),

    // ARAM accesses
    .aram_16(aram_16), .aram_addr(aram_addr_sd), .aram_din(aram_din_sd), 
`ifdef SNES_SAVESTATE
    .aram_dout(), .aram_req(aram_req), .aram_req_ack(), .aram_we(aram_we_sd),
`else
    .aram_dout(aram_dout), .aram_req(aram_req), .aram_req_ack(), .aram_we(aram_we_sd),
`endif

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
`ifdef SNES_SAVESTATE
    .ss_hold(ss_freeze), .ss_sel(ss_vram_sel), .ss_req(ss_mem_req), .ss_we(ss_mem_we),
    .ss_addr(ss_mem_addr[15:0]), .ss_din(ss_mem_din), .ss_ack(ss_vr_ack), .ss_q(ss_vr_q),
    .ss_reg_a(ss_a), .ss_reg_d(ss_d), .ss_reg_we(ss_we), .ss_reg_q(ss_vr_regs_q),
`endif
    .clk(mclk), 
    .vram1_addr(vram1_addr_sd), .vram1_req(vram1_req), .vram1_ack(), 
    .vram1_we(~vram1_we_n_old), .vram1_din(vram1_din), .vram1_dout(VRAM1_Q), 
    .vram2_addr(vram2_addr_sd), .vram2_req(vram2_req), .vram2_ack(),
    .vram2_we(~vram2_we_n_old),  .vram2_din(vram2_din), .vram2_dout(VRAM2_Q)
);
`endif

`ifdef SNES_SAVESTATE
wire [63:0] ss_flags = {ram_mask, rom_mask, ram_size, rom_size, rom_type};
// Base console only until the matching cartridge state ports are implemented.
wire ss_supported = rom_type[7:3] == 0 && loaded;
wire [7:0] ss_top_q;
savestate #(
`ifdef HZ120
    .VARIANT(1)
`else
    .VARIANT(0)
`endif
) ss_engine (
    .clk(mclk), .clkref(ss_phase), .resetn(resetn & ~loading),
    .mapper_flags(ss_flags), .ss_supported(ss_supported), .ss_point(ss_point && enable && bs_fifo_empty && !bs_busy),
    .ss_freeze(ss_freeze), .ss_reset(ss_reset), .ss_loaded(ss_loaded),
    .ss_edge_reset(ss_edge_reset), .ss_active(ss_active),
    .ss_a(ss_a), .ss_din(ss_d), .ss_we(ss_we), .ss_dout(ss_regs_q | ss_sd_regs_q | ss_vr_regs_q | ss_top_q),
    .sd_douta(8'b0), .sd_doutb(8'b0), .sd_ld_we(), .sd_ld_douta(), .sd_ld_doutb(),
    .mem_addr(ss_mem_addr), .mem_din(ss_mem_din), .mem_we(ss_mem_we), .mem_req(ss_mem_req),
    .mem_ack(ss_mem_ack), .mem_q(ss_mem_q),
    .op(ss_op), .op_stb(ss_op_stb), .ss_status(ss_status),
    .img_raddr(ss_img_raddr), .img_rd_stb(ss_img_rd_stb), .img_taken(ss_img_taken),
    .img_abort(ss_img_abort), .img_rdy(ss_img_rdy), .img_q(ss_img_q),
    .img_waddr(ss_img_waddr), .img_wdin(ss_img_wdin), .img_wr_stb(ss_img_wr_stb)
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

// The 64-byte loader preamble omits the extended header at $7FB0. Read
// its GSU expansion-RAM size from the ordinary ROM stream before reset is
// released; no loader/protocol change is needed.
gsu_ram_mask_from_rom gsu_ram_metadata (
    .clk(mclk), .resetn(resetn), .loading(loading),
    .header_finished(header_finished), .rom_addr(loader_addr),
    .rom_d(loader_do), .rom_strb(loader_do_valid), .ram_mask(gsu_ram_mask)
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

iosys_bl616 #(
`ifdef SNES_SAVESTATE
    .SS_IF(1),
`endif
.CORE_ID(2), .FREQ(21_484_000), .SAVE_IF(1), .SAVE_AW(SAVE_AW), .SAVE_RDY(1)) iosys (
`ifdef SNES_SAVESTATE
    .ss_op(ss_op), .ss_op_stb(ss_op_stb), .ss_status(ss_status),
    .ss_img_raddr(ss_img_raddr), .ss_img_rd_stb(ss_img_rd_stb), .ss_img_taken(ss_img_taken),
    .ss_img_abort(ss_img_abort), .ss_img_rdy(ss_img_rdy), .ss_img_q(ss_img_q),
    .ss_img_waddr(ss_img_waddr), .ss_img_wdin(ss_img_wdin), .ss_img_wr_stb(ss_img_wr_stb),
`endif

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
    .sv_rreq(sv_rreq), .sv_rack(sv_rack), .sv_q(sv_q), .sv_core_we(
`ifdef SNES_SAVESTATE
    ss_loaded | sv_core_we
`else
    sv_core_we
`endif
)
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

`ifdef SNES_SAVESTATE
reg [7:0] ss_top_q_r;
assign ss_top_q = ss_top_q_r;
always @* begin
    ss_top_q_r = 0;
    case (ss_a)
    13'h1b60: ss_top_q_r = 8'(cpu_port);
    13'h1b61: ss_top_q_r = 8'(cpu_req);
    13'h1b62: ss_top_q_r = 8'(cpu_ds[1:0]);
    13'h1b63: ss_top_q_r = 8'(cpu_din[7:0]);
    13'h1b64: ss_top_q_r = 8'(cpu_din[15:8]);
    13'h1b65: ss_top_q_r = 8'(cpu_addr[7:0]);
    13'h1b66: ss_top_q_r = 8'(cpu_addr[15:8]);
    13'h1b67: ss_top_q_r = 8'(cpu_addr[22:16]);
    13'h1b68: ss_top_q_r = 8'(cpu_we);
    13'h1b69: ss_top_q_r = 8'(rom_addr_sd[7:0]);
    13'h1b6a: ss_top_q_r = 8'(rom_addr_sd[15:8]);
    13'h1b6b: ss_top_q_r = 8'(rom_addr_sd[22:16]);
    13'h1b6c: ss_top_q_r = 8'(wram_addr_sd[7:0]);
    13'h1b6d: ss_top_q_r = 8'(wram_addr_sd[15:8]);
    13'h1b6e: ss_top_q_r = 8'(wram_addr_sd[16:16]);
    13'h1b6f: ss_top_q_r = 8'(wram_wr_r);
    13'h1b70: ss_top_q_r = 8'(wram_rd_r);
    13'h1b71: ss_top_q_r = 8'(bsram_addr[7:0]);
    13'h1b72: ss_top_q_r = 8'(bsram_addr[15:8]);
    13'h1b73: ss_top_q_r = 8'(bsram_addr[19:16]);
    13'h1b74: ss_top_q_r = 8'(bsram_rd_r);
    13'h1b75: ss_top_q_r = 8'(bsram_wr_r);
    13'h1b76: ss_top_q_r = 8'(aram_addr_sd[7:0]);
    13'h1b77: ss_top_q_r = 8'(aram_addr_sd[15:8]);
    13'h1b78: ss_top_q_r = 8'(aram_din_sd[7:0]);
    13'h1b79: ss_top_q_r = 8'(aram_din_sd[15:8]);
    13'h1b7a: ss_top_q_r = 8'(aram_we_sd);
    13'h1b7b: ss_top_q_r = 8'(aram_rd_r);
    13'h1b7c: ss_top_q_r = 8'(aram_wr_r);
    13'h1b7d: ss_top_q_r = 8'(aram_req);
    13'h1b7e: ss_top_q_r = 8'(vram1_addr_sd[7:0]);
    13'h1b7f: ss_top_q_r = 8'(vram1_addr_sd[14:8]);
    13'h1b80: ss_top_q_r = 8'(vram2_addr_sd[7:0]);
    13'h1b81: ss_top_q_r = 8'(vram2_addr_sd[14:8]);
    13'h1b82: ss_top_q_r = 8'(vram1_we_n_old);
    13'h1b83: ss_top_q_r = 8'(vram2_we_n_old);
    13'h1b84: ss_top_q_r = 8'(vram1_req);
    13'h1b85: ss_top_q_r = 8'(vram2_req);
    13'h1b86: ss_top_q_r = 8'(vram1_din[7:0]);
    13'h1b87: ss_top_q_r = 8'(vram2_din[7:0]);
    13'h1b88: ss_top_q_r = 8'(bs_req_tog);
    13'h1b89: ss_top_q_r = 8'(bs_ack_sync[2:0]);
    13'h1b8a: ss_top_q_r = 8'(bs_busy);
    13'h1b8b: ss_top_q_r = 8'(bs_owner);
    13'h1b8c: ss_top_q_r = 8'(bs_we_r);
    13'h1b8d: ss_top_q_r = 8'(bs_addr_r[7:0]);
    13'h1b8e: ss_top_q_r = 8'(bs_addr_r[15:8]);
    13'h1b8f: ss_top_q_r = 8'(bs_addr_r[16:16]);
    13'h1b90: ss_top_q_r = 8'(bs_din_r[7:0]);
    13'h1b91: ss_top_q_r = 8'(snes_bsram_hold[7:0]);
    13'h1b92: ss_top_q_r = 8'(snes_bsram_shadow);
    default: ;
    endcase
end
`endif

endmodule



// Super FX physical RAM address lines: legacy Star Fox has 32 KiB even
// though its normal SRAM-size byte is zero. Extended-header carts declare
// working RAM separately; battery-backed RAM may use the normal size byte.
module gsu_ram_mask_from_rom (
    input clk, resetn, loading, header_finished,
    input [22:0] rom_addr,
    input [7:0] rom_d,
    input rom_strb,
    output reg [23:0] ram_mask = 24'h007fff
);
reg [3:0] expansion_size = 0, save_size = 0;
always @(posedge clk) begin
    if (!resetn || (loading && !header_finished)) begin
        expansion_size <= 0;
        save_size <= 0;
        ram_mask <= 24'h007fff;
    end else if (loading && rom_strb) begin
        case (rom_addr)
        23'h007fbd: expansion_size <= rom_d[3:0];
        23'h007fd8: save_size <= rom_d[3:0];
        23'h007fda: begin
            if (rom_d == 8'h33 && expansion_size > save_size)
                ram_mask <= (24'd1024 << expansion_size) - 1'd1;
            else if (save_size != 0)
                ram_mask <= (24'd1024 << save_size) - 1'd1;
            else
                ram_mask <= 24'h007fff;
        end
        default: ;
        endcase
    end
end
endmodule
