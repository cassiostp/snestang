// cosim_top: the SNES co-simulation DUT. A small top around the REAL
// snestang interface logic -- iosys_bl616 (UART protocol, OSD text, save
// channel) and sdram_snes (sdram_cl2_2ch: the SDRAM controller with the
// BSRAM port) -- plus snestang_top's BSRAM/save-channel bridge, a behavioral
// SDRAM chip, SNES-like bus traffic and test hooks. No game, no video, no
// audio: this exercises firmware<->core interactions (pad frames, combos,
// save dumps/restores through the shared BSRAM port, reset, MODE,
// core_config) without hardware.
//
// CYCLES AND CLOCKS
//   clk/fclk/hclk/resetn come from the C++ bridge. clk is the SNES mclk:
//   iosys and the bridge run on it (as snestang_top wires them). fclk must
//   be exactly 3x clk (sdram_snes's 6-cycle frame resyncs on every clkref
//   posedge and needs clkref at 1/6 of clk -- clkref toggles on clk here,
//   standing in for the SNES core's DOT_CLK_CE). hclk is tied to clk by the
//   bridge: it only feeds textdisp's render pipeline, whose pixels nobody
//   observes (OSD text is snapshotted straight out of the DPB array, below).
//   One sim tick (firmware sim_time, 1/21.492MHz) is one clk period.
//
// PROGRAMMING MODEL
//   The generated iosys_bl616_cosim answers core-ID replies with the
//   cosim_core_id input (see Makefile: the ONLY difference from the real
//   iosys_bl616.v, made by mechanical sed at build time and verified by
//   diff). Programming a bitstream = the bridge sets cosim_core_id and
//   pulses resetn, like hardware loading fresh logic. SDRAM contents are
//   RETAINED across reset (external chip), matching hardware.
//   silence=1 (MODE blackout) forces both UART lines idle; the bridge ends
//   it with a reset pulse and cosim_core_id=0 (flash bitstream), after which
//   the firmware reboots.
//
// GAME/TRAFFIC MODEL
//   The CPU port (ROM/WRAM words) and the ARAM port (SPC audio RAM) get
//   toggled SNES-like traffic (LFSR-driven, deterministic): a CPU access
//   every 12 clk (ROM read, WRAM read), an ARAM read every 36 clk. The
//   game's BSRAM (save RAM) accesses go through the SAME bridge arbiter as
//   the save channel, exactly like snestang_top wires them: SNES first,
//   save bytes slipping into idle slots, so dumps genuinely contend with
//   game traffic for the controller's single BSRAM port.
//   churn_en: the "game" continuously scribbles BSRAM (combo-during-dump);
//   every game write pulses sv_core_we -- what snestang_top's
//   `sv_core_we = bsram_wr & ~bsram_wr_r` does for real SNES writes -- so
//   iosys dirties the save and owes the MCU a 0x0B notice.
//   poke_valid/poke_off/poke_data/poke_ack: single game-path BSRAM writes
//   for wram-write/wram-burst (and poke-save). Poke wins over churn and
//   normal CPU traffic for its slot.
//
// OBSERVABILITY (all real unless noted)
//   core_config/video_config/overlay: straight out of iosys (expect-config-bit
//   reads the real register). rom_bytes: ROM payload bytes consumed (firmware
//   streams the ROM; no loader parses it here). sdram_busy: controller init.
//   OSD text / save RAM: read by the C++ bridge DIRECTLY out of the
//   behavioral arrays (gowin_dpb_menu.mem, sdram_chip.mem, both
//   `verilator public`), no model clocking per cell. The char buffer lives
//   at DPB $000-$37F = {1'b0, y[4:0], x[4:0]} (32x28). Save RAM is the
//   BSRAM window: byte address 0xF0_0000 + offset (bank 1 word 0x78_0000,
//   as sdram_cl2_2ch maps {5'b01_111, bsram_addr[19:0]}).
module cosim_top (
    input wire clk,
    input wire fclk,
    input wire hclk,
    input wire resetn,

    input wire [11:0] joy1,
    input wire [11:0] joy2,

    input wire uart_rx,
    output wire uart_tx,
    input wire silence,
    input wire [15:0] cosim_core_id,

    output wire [31:0] core_config,
    output wire [31:0] video_config,
    output wire overlay,
    output wire sdram_busy,
    output reg [31:0] rom_bytes,
    // TX-pending for the bridge's idle jump: a reply owed or a frame on the
    // wire. Hierarchical into iosys (cosim-owned top; the DUT itself is
    // untouched): send_state covers every TX frame (including SEND_SAVE_RDY
    // waiting a BSRAM read), response_* the core-ID / config-string
    // handoff (RX posts, TX picks up a tick or two later), sv_rd_req/ack
    // the block-reply handoff, sv_notify the dirty-notice path -- and,
    // unlike the NES top, sv_req/sv_ack: with SAVE_RDY=1 a restore byte can
    // sit in RECV_SAVE_WAIT until the SDRAM acks the write, and jumping the
    // idle gap there would stall the save engine forever. (A joypad frame
    // due on its 20 ms timer is NOT included: delaying it by a jump is
    // harmless, the firmware polls.)
    output wire tx_pending,
    input wire poke_valid,
    input wire [15:0] poke_off,   // offset into the 128 KB BSRAM window
    input wire [7:0] poke_data,
    output reg poke_ack,
    input wire churn_en
);

import configPackage::*;

reg clkref = 0;
always @(posedge clk) clkref <= ~clkref;

// ---- UART gating (MODE blackout) ----
wire uart_rx_iosys = silence ? 1'b1 : uart_rx;
wire uart_tx_iosys;
assign uart_tx = silence ? 1'b1 : uart_tx_iosys;

// ---- save channel (iosys <-> bridge), as snestang_top wires it ----
wire [16:0] sv_addr;
wire [7:0]  sv_din;
wire        sv_req, sv_rreq;
reg         sv_ack_r = 0, sv_rack_r = 0;
reg  [7:0]  sv_q_r = 0;
wire [7:0]  bsram_dout;                  // the sdram controller's sticky read reg
reg  [7:0]  snes_bsram_hold = 0;         // the SNES's last read data, kept while
reg         snes_bsram_shadow = 0;       // the save channel owns the port
reg         sv_core_we = 0;

// ---- ROM sink: count what the firmware streams (no loader here) ----
wire [7:0] rom_loading_unused;
wire [7:0] rom_do;
wire rom_do_valid;
always @(posedge clk) begin
    if (!resetn)
        rom_bytes <= 0;
    else if (rom_do_valid)
        rom_bytes <= rom_bytes + 1;
end

assign tx_pending = (sys.send_state != 4'd0) || (sys.response_req != sys.response_ack) ||
                    (sys.sv_rd_req != sys.sv_rd_ack) || sys.sv_notify ||
                    (sys.sv_req != sys.sv_ack);

iosys_bl616_cosim #(
    .FREQ(21_492_000),
    .SAVE_IF(1),
    .SAVE_AW(17),
    .SAVE_RDY(1)
) sys (
    .clk(clk),
    .hclk(hclk),
    .resetn(resetn),
    .cosim_core_id(cosim_core_id),

    .overlay(overlay),
    .overlay_x(8'h00),
    .overlay_y(8'h00),
    .overlay_color(),
    .joy1(joy1),
    .joy2(joy2),
    .hid1(),
    .hid2(),

    .rom_loading(rom_loading_unused),
    .rom_do(rom_do),
    .rom_do_valid(rom_do_valid),

    .mgmt_address(),
    .mgmt_read(),
    .mgmt_readdata(16'h0),
    .mgmt_write(),
    .mgmt_writedata(),
    .fdd_request(2'b00),

    .kbd_data(),
    .kbd_data_valid(),

    .core_config(core_config),
    .video_config(video_config),

    .sv_addr(sv_addr),
    .sv_din(sv_din),
    .sv_we(),
    .sv_req(sv_req),
    .sv_ack(sv_ack_r),
    .sv_rreq(sv_rreq),
    .sv_rack(sv_rack_r),
    .sv_q(sv_q_r),
    .sv_core_we(sv_core_we),

    .uart_rx(uart_rx_iosys),
    .uart_tx(uart_tx_iosys)
);

// ---- Save-RAM <-> BSRAM bridge: snestang_top's arbiter, copied verbatim
// (except the SNES-bus edge detectors, which the traffic generator below
// replaces by toggling snes_bs_tog directly). The SNES cartridge bus and
// the save channel share the controller's single BSRAM port; SNES first,
// one byte at a time; the controller toggles bs_req_ack once per access.
reg         snes_bs_tog = 0, snes_bs_seen = 0;
reg         sv_w_seen = 0, sv_r_seen = 0;
reg         bs_req_tog = 0;                 // -> controller .bsram_req
wire        bs_req_ack;                     // <- controller .bsram_req_ack
reg  [2:0]  bs_ack_sync = 0;                // 2FF sync of bs_req_ack into clk
wire        bs_ack = bs_ack_sync[2];
reg         bs_busy = 0;
reg         bs_owner = 0;                   // 0: SNES access, 1: save access
reg         bs_we_r = 0;
reg  [16:0] bs_addr_r = 0;
reg  [7:0]  bs_din_r = 0;
wire        snes_bs_new = snes_bs_tog != snes_bs_seen;
wire        sv_w_new    = sv_req != sv_w_seen;
wire        sv_r_new    = sv_rreq != sv_r_seen;
wire        bs_free     = bs_req_tog == bs_ack;
wire        bs_issue_ok = ~bs_busy | bs_free;   // idle, or acked this very clock

// game-side BSRAM request registers (what snestang_top calls bsram_* regs)
reg  [16:0] bsram_addr = 0;
reg  [7:0]  bsram_din = 0;
reg         bsram_we = 0;

always @(posedge clk) begin
    if (!resetn) begin
        snes_bs_seen <= 0;
        sv_w_seen <= 0;
        sv_r_seen <= 0;
        bs_req_tog <= 0;
        bs_ack_sync <= 0;
        bs_busy <= 0;
        bs_owner <= 0;
        bs_we_r <= 0;
        bs_addr_r <= 0;
        bs_din_r <= 0;
        sv_ack_r <= 0;
        sv_rack_r <= 0;
        sv_q_r <= 0;
    end else begin
        bs_ack_sync <= {bs_ack_sync[1:0], bs_req_ack};
        if (bs_busy && bs_free) begin           // the access just completed
            bs_busy <= 0;
            if (bs_owner) begin
                if (bs_we_r) sv_ack_r <= ~sv_ack_r;
                else begin
                    sv_q_r <= bsram_dout;       // the controller's sticky read reg
                    sv_rack_r <= ~sv_rack_r;
                end
            end
        end
        if (bs_issue_ok && snes_bs_new) begin
            snes_bsram_shadow <= 0;             // the SNES gets the port's data again
            bs_addr_r <= bsram_addr[16:0];
            bs_din_r  <= bsram_din;
            bs_we_r   <= bsram_we;
            bs_owner  <= 0;
            bs_busy   <= 1;
            bs_req_tog <= ~bs_req_tog;
            snes_bs_seen <= snes_bs_tog;
        end else if (bs_issue_ok && sv_w_new) begin
            if (!snes_bsram_shadow) begin       // keep the SNES's last read data
                snes_bsram_hold <= bsram_dout;
                snes_bsram_shadow <= 1;
            end
            bs_addr_r <= sv_addr;
            bs_din_r  <= sv_din;
            bs_we_r   <= 1;
            bs_owner  <= 1;
            bs_busy   <= 1;
            bs_req_tog <= ~bs_req_tog;
            sv_w_seen <= sv_req;
        end else if (bs_issue_ok && sv_r_new) begin
            if (!snes_bsram_shadow) begin       // keep the SNES's last read data
                snes_bsram_hold <= bsram_dout;
                snes_bsram_shadow <= 1;
            end
            bs_addr_r <= sv_addr;
            bs_din_r  <= 8'h0;
            bs_we_r   <= 0;
            bs_owner  <= 1;
            bs_busy   <= 1;
            bs_req_tog <= ~bs_req_tog;
            sv_r_seen <= sv_rreq;
        end
    end
end

// ---- SDRAM: real controller (bank 0/1: ROM+WRAM, bank 1: BSRAM, bank 2:
// ARAM) + behavioral chip, as snestang_top ----
wire [SDRAM_ROW_WIDTH-1:0] sdram_a;
wire [1:0] sdram_ba;
wire [SDRAM_DATA_WIDTH/8-1:0] sdram_dqm;
wire sdram_ncs, sdram_nwe, sdram_nras, sdram_ncas, sdram_cke;
wire [SDRAM_DATA_WIDTH-1:0] sdram_dq;

// CPU port (ROM + WRAM): the mclk-domain regs of snestang_top's bus block.
reg [21:0] cpu_addr = 0;          // WORD address (the port takes addr[22:1])
reg        cpu_req = 0;
reg        cpu_we = 0;
reg [1:0]  cpu_ds = 0;
reg        cpu_port = 0;
reg [15:0] cpu_din = 0;
wire [15:0] cpu_port0, cpu_port1; // output registers; the game is not here

reg aram_req = 0;
reg [15:0] aram_addr = 0;               // SPC RAM byte address
wire [15:0] aram_dout;                   // audio samples; nobody listens here

sdram_snes sdram (
    .clk(fclk), .mclk(clk), .clkref(clkref), .resetn(resetn), .busy(sdram_busy),

    .SDRAM_DQ(sdram_dq), .SDRAM_A(sdram_a), .SDRAM_BA(sdram_ba),
    .SDRAM_nCS(sdram_ncs), .SDRAM_nWE(sdram_nwe), .SDRAM_nRAS(sdram_nras),
    .SDRAM_nCAS(sdram_ncas), .SDRAM_CKE(sdram_cke), .SDRAM_DQM(sdram_dqm),

    .cpu_addr(cpu_addr), .cpu_din(cpu_din), .cpu_port(cpu_port),
    .cpu_port0(cpu_port0), .cpu_port1(cpu_port1), .cpu_req(cpu_req),
    .cpu_req_ack(), .cpu_we(cpu_we), .cpu_ds(cpu_ds),

    .bsram_addr({3'b0, bs_addr_r}), .bsram_dout(bsram_dout), .bsram_din(bs_din_r),
    .bsram_req(bs_req_tog), .bsram_req_ack(bs_req_ack), .bsram_we(bs_we_r),

    .aram_16(1'b0), .aram_addr(aram_addr), .aram_din(16'h0),
    .aram_dout(aram_dout), .aram_req(aram_req), .aram_req_ack(), .aram_we(1'b0),

    .rv_addr(22'h0), .rv_din(16'h0),
    .rv_ds(2'b00), .rv_dout(), .rv_req(1'b0), .rv_req_ack(), .rv_we(1'b0)
);

sdram_chip chip (
    .fclk(fclk),
    .A(sdram_a),
    .BA(sdram_ba),
    .DQM(sdram_dqm),
    .nCS(sdram_ncs),
    .nWE(sdram_nwe),
    .nRAS(sdram_nras),
    .nCAS(sdram_ncas),
    .SDRAM_DQ(sdram_dq)
);

// ---- SNES-like bus traffic + game BSRAM writes (clk domain) ----
// Deterministic 16-bit LFSR (x^16+x^14+x^13+x^11+1), never zero.
reg [15:0] lfsr = 16'hACE1;
function [15:0] lfsr_next(input [15:0] s);
    lfsr_next = {s[14:0], s[15] ^ s[13] ^ s[12] ^ s[10]};
endfunction

// The game's battery RAM: 32 KB window at the bottom of the 128 KB BSRAM.
localparam [16:0] BSRAM_BASE = 17'h00000;

reg [15:0] tc = 0;
reg poke_busy = 0;
reg [15:0] churn_div = 0;
reg [1:0] poke_hold = 0;

always @(posedge clk) begin
    if (!resetn) begin
        cpu_addr <= 0;
        cpu_req <= 0;
        cpu_we <= 0;
        cpu_ds <= 0;
        cpu_port <= 0;
        cpu_din <= 0;
        aram_req <= 0;
        aram_addr <= 0;
        bsram_addr <= 0;
        bsram_din <= 0;
        bsram_we <= 0;
        snes_bs_tog <= 0;
        sv_core_we <= 0;
        poke_ack <= 0;
        poke_busy <= 0;
        poke_hold <= 0;
        tc <= 0;
        churn_div <= 0;
        lfsr <= 16'hACE1;
    end else begin
        tc <= tc + 1;
        lfsr <= lfsr_next(lfsr);
        sv_core_we <= 0;
        // Requests are toggle handshakes: one toggle per access, spaced far
        // apart, so the controller's frame sampling (accepted at cycle[0],
        // acked at cycle[1]) can never miss one. Requests stay parked long
        // after the ack -- as in the real top, where the bus block holds
        // them until the next SNES access.
        //
        // poke_ack is level (not a pulse): it stays up from accept until the
        // bridge releases poke_valid, so a batch-granularity sampler cannot
        // miss it between evaluations.
        if (!poke_valid)
            poke_ack <= 0;

        if (poke_valid && !poke_busy) begin
            // Test hook: one game-path BSRAM write (dirties the save),
            // issued as a SNES-side access through the bridge.
            poke_busy <= 1;
            poke_hold <= 3;
            bsram_addr <= BSRAM_BASE + {1'b0, poke_off};
            bsram_din <= poke_data;
            bsram_we <= 1;
            snes_bs_tog <= ~snes_bs_tog;
            sv_core_we <= 1;
            poke_ack <= 1;
        end else if (!poke_valid) begin
            poke_busy <= 0;
            // CPU (ROM/WRAM): one access every 12 clk, alternating.
            if (tc % 12 == 0) begin
                cpu_req <= ~cpu_req;
                if (tc % 24 == 0) begin
                    // ROM read (bank 0, low 1 MB).
                    cpu_port <= 0;
                    cpu_we <= 0;
                    cpu_addr <= {8'h00, lfsr[15:0]} & 22'h0FFFFF;
                    cpu_ds <= 2'b11;
                end else begin
                    // WRAM read (7E/7F:0000-FFFF = words 0x3F0000+).
                    cpu_port <= 1;
                    cpu_we <= 0;
                    cpu_addr <= 22'h3F0000 + ({6'h0, lfsr} & 22'h0FFF);
                    cpu_ds <= 2'b11;
                end
            end
            // The game also polls its battery RAM (a read every 64 clk):
            // the save channel then has to interleave with SNES reads, which
            // is what the bridge's shadow/hold registers are for.
            if (tc % 64 == 8) begin
                bsram_addr <= BSRAM_BASE + {2'h0, lfsr[14:0]};
                bsram_we <= 0;
                snes_bs_tog <= ~snes_bs_tog;
            end
            // ARAM (SPC audio RAM): a read every 36 clk (bank 2).
            if (tc % 36 == 0) begin
                aram_addr <= {lfsr[13:0], 1'b0};   // even byte addresses
                aram_req <= ~aram_req;
            end
            // The game scribbles its battery RAM as work RAM
            // (combo-during-dump): one BSRAM write every 48 clk, sweeping a
            // 32 KB window (the largest BSRAM game).
            if (churn_en && (tc % 48 == 0)) begin
                churn_div <= churn_div + 1;
                bsram_addr <= BSRAM_BASE + {2'h0, lfsr[14:0] ^ churn_div[14:0]};
                bsram_din <= lfsr[7:0] ^ churn_div[7:0];
                bsram_we <= 1;
                snes_bs_tog <= ~snes_bs_tog;
                sv_core_we <= 1;
            end
        end
        // Poke re-toggles nothing; the bridge takes the single toggle. The
        // write data must hold until the bridge issues the access (it
        // samples bsram_* on the toggle's clock, so this hold only keeps
        // the "game drove this byte" story straight).
        if (poke_hold != 0)
            poke_hold <= poke_hold - 1'd1;
    end
end

endmodule
