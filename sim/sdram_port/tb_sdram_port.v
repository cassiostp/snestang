// Port-level testbench for sdram_cl2_2ch's CPU lane and second-reader
// (CPU2) lane, against the behavioral SDRAM chip from sim/cosim.
//
// The S-CPU side is driven like snestang_top drives it: the ROM/WRAM edge
// detectors below are copied from snestang_top.v, and an S-CPU-like
// sequencer issues 6/8/12-mclk bus cycles (ROM reads, WRAM reads/writes, I/O
// cycles, A->B DMA cycles with a ROM read and a WRAM write in one cycle).
// Every S-CPU read is checked at the end of its cycle, where the real CPU
// samples, and the mclk edge at which the right word first showed up on the
// port is recorded. A second master on CPU2 issues reads like the SA-1 does
// (one outstanding request, ack when the word is in cpu2_dout) and checks
// every word. A low-rate BSRAM requester runs underneath.
//
// Scenarios (one per run, +SCEN=n):
//   0  S-CPU only, CPU2 idle (with +TRACE, dumps the SDRAM command bus and
//      the CPU lane's outputs every fclk for the identity check)
//   1  S-CPU + CPU2 back-to-back random reads (saturation)
//   2  S-CPU + CPU2 SA-1-like: mostly sequential words, random gaps
// Build with -DBASELINE to run the unmodified controller (no CPU2 ports).
// Build with -DSDCMC_STABLE to also prove the fclk->mclk multicycle-3
// window: at every mclk-domain sample, no fclk launch in the SDRAM->SNES
// cone may have changed in the previous 3 fclk (a change exactly on the
// coincident sampling edge is benign and ignored).
`timescale 1ns/1ps

module tb_sdram_port;

reg fclk = 0, mclk = 0;
always #5  fclk = ~fclk;            // fclk = 3x mclk, coincident rising edges
always #15 mclk = ~mclk;

integer scen = 0;
integer ncycles = 20000;
reg trace = 0;
integer tf;
integer seed = 1;

// clkref: DOT_CLK_CE, a 1-mclk pulse every 4 mclk, with the PPU's two long
// 6-mclk dots per line
reg clkref = 0;
integer dot_cnt = 0, dot_len = 4, dot_num = 0;
always @(posedge mclk) begin
    clkref <= dot_cnt == 0;
    if (dot_cnt == dot_len - 1) begin
        dot_cnt <= 0;
        dot_num <= dot_num == 340 ? 0 : dot_num + 1;
        dot_len <= (dot_num == 322 || dot_num == 326) ? 6 : 4;
    end else
        dot_cnt <= dot_cnt + 1;
end

reg resetn = 0;

// ---- DUT ----------------------------------------------------------------
wire [15:0] sdram_dq;
wire [12:0] sdram_a;
wire [1:0]  sdram_ba, sdram_dqm;
wire sdram_ncs, sdram_nwe, sdram_nras, sdram_ncas, sdram_cke;
wire sdram_busy;

reg         cpu_req = 0;
reg  [1:0]  cpu_ds = 0;
reg [15:0]  cpu_din = 0;
reg [22:0]  cpu_addr = 0;
reg         cpu_we = 0;
reg         cpu_port = 0;
wire [15:0] cpu_port0, cpu_port1;
wire        cpu_req_ack;

reg  [22:1] cpu2_addr = 0;
reg         cpu2_req = 0;
wire        cpu2_req_ack;
wire [15:0] cpu2_dout;

reg  [19:0] bs_addr = 0;
reg         bs_req = 0, bs_we = 0;
reg  [7:0]  bs_din = 0;
wire [7:0]  bsram_dout;
wire        bs_req_ack;

reg  [15:0] aram_addr = 0;
reg         aram_req = 0;
reg  [15:0] aram_din_r = 0;
reg         aram_we_r = 0;
wire [15:0] aram_dout;

sdram_snes dut (
    .clk(fclk), .mclk(mclk), .clkref(clkref), .resetn(resetn), .busy(sdram_busy),
    .SDRAM_DQ(sdram_dq), .SDRAM_A(sdram_a), .SDRAM_BA(sdram_ba),
    .SDRAM_nCS(sdram_ncs), .SDRAM_nWE(sdram_nwe), .SDRAM_nRAS(sdram_nras),
    .SDRAM_nCAS(sdram_ncas), .SDRAM_CKE(sdram_cke), .SDRAM_DQM(sdram_dqm),
    .cpu_addr(cpu_addr[22:1]), .cpu_din(cpu_din), .cpu_port(cpu_port),
    .cpu_port0(cpu_port0), .cpu_port1(cpu_port1), .cpu_req(cpu_req),
    .cpu_req_ack(cpu_req_ack), .cpu_we(cpu_we), .cpu_ds(cpu_ds),
`ifndef BASELINE
    .cpu2_addr(cpu2_addr), .cpu2_dout(cpu2_dout), .cpu2_req(cpu2_req), .cpu2_req_ack(cpu2_req_ack),
`endif
    .bsram_addr(bs_addr), .bsram_dout(bsram_dout), .bsram_din(bs_din),
    .bsram_req(bs_req), .bsram_req_ack(bs_req_ack), .bsram_we(bs_we),
    .aram_16(1'b0), .aram_addr(aram_addr), .aram_din(aram_din_r),
    .aram_dout(aram_dout), .aram_req(aram_req), .aram_req_ack(), .aram_we(aram_we_r),
    .rv_addr(22'h0), .rv_din(16'h0),
    .rv_ds(2'b00), .rv_dout(), .rv_req(1'b0), .rv_req_ack(), .rv_we(1'b0)
);
`ifdef BASELINE
assign cpu2_req_ack = 0;
assign cpu2_dout = 0;
`endif

sdram_chip chip (
    .fclk(fclk), .A(sdram_a), .BA(sdram_ba), .DQM(sdram_dqm),
    .nCS(sdram_ncs), .nWE(sdram_nwe), .nRAS(sdram_nras), .nCAS(sdram_ncas),
    .SDRAM_DQ(sdram_dq)
);

// ROM contents: a unique word per address. ROM is the first 1M words of
// bank 0; WRAM is words 0x3F_0000+ (7E/7F, {6'b111_111, addr[16:0]} >> 1).
function [15:0] rom_word(input [21:0] w);
    rom_word = w[15:0] ^ {w[21:16], 10'h2a5} ^ 16'h5a3c;
endfunction
reg [7:0] wram_shadow [0:131071];
integer i;
initial begin
    for (i = 0; i < (1 << 20); i = i + 1) chip.mem[i] = rom_word(i);
    for (i = 0; i < 131072; i = i + 1) begin
        wram_shadow[i] = i[7:0] ^ i[15:8] ^ 8'h69;
        if (i[0]) chip.mem[24'h3F_0000 + (i >> 1)][15:8] = wram_shadow[i];
        else      chip.mem[24'h3F_0000 + (i >> 1)][7:0]  = wram_shadow[i];
    end
    for (i = 0; i < 65536; i = i + 1)
        chip.mem[24'h78_0000 + i] = {i[7:0] ^ 8'h33, i[7:0] ^ 8'hcc};
    // the controller's toggle acks have no reset; the FPGA powers them up at 0
    dut.cpu_req_ack = 0; dut.bsram_req_ack = 0; dut.aram_req_ack = 0; dut.rv_req_ack = 0;
`ifndef BASELINE
    dut.cpu2_req_ack = 0;
`endif
end

// ---- S-CPU bus (what main.v/SNES present to snestang_top) ----------------
reg [22:0] ROM_ADDR = 0;
reg        ROM_CE_N = 1;
reg [16:0] WRAM_ADDR = 0;
reg        WRAM_CE_N = 1, WRAM_RD_N = 1, WRAM_WE_N = 1;
reg [7:0]  WRAM_D = 0;
wire       wram_rd = ~WRAM_CE_N & ~WRAM_RD_N;
wire       wram_wr = ~WRAM_CE_N & ~WRAM_WE_N;
wire [22:0] rom_addr = ROM_ADDR;
reg [22:0] rom_addr_sd = 0;
reg [16:0] wram_addr_sd = 0;
reg        wram_wr_r = 0, wram_rd_r = 0;
wire       loading = 0;

// copied from snestang_top.v ("Generate SDRAM signals"), ROM and WRAM parts
always @(posedge mclk) begin
    if (~resetn) begin
    end else begin
        if (~loading && ~ROM_CE_N && rom_addr_sd != rom_addr) begin
            rom_addr_sd <= rom_addr;
            cpu_addr <= rom_addr;
            cpu_req <= ~cpu_req;
            cpu_we <= loading;
            cpu_ds <= 2'b11;
            cpu_port <= 0;
        end
        wram_rd_r <= wram_rd; wram_wr_r <= wram_wr;
        if ((wram_rd && WRAM_ADDR[16:1] != wram_addr_sd[16:1]) || (wram_rd & ~wram_rd_r) || (wram_wr & ~wram_wr_r)) begin
            wram_addr_sd <= WRAM_ADDR;
            cpu_req <= ~cpu_req;
            cpu_addr <= {6'b111_111, WRAM_ADDR[16:0]};
            cpu_we <= wram_wr;
            cpu_ds <= {WRAM_ADDR[0], ~WRAM_ADDR[0]};
            cpu_din <= {WRAM_D, WRAM_D};
            cpu_port <= 1;
        end
    end
end

// S-CPU sequencer: one bus cycle of len 6/8/12 mclk; address out at the
// cycle's first edge, sampled at its last (where SYSCLKF_CE latches data)
localparam T_ROM = 0, T_WRD = 1, T_WWR = 2, T_IO = 3, T_DMA = 4;
integer cyc_len = 6, cyc_pos = 0, cyc_type = T_IO;
integer phase = 0;
reg [22:0] cur_rom = 0;
reg [16:0] cur_wram = 0;
reg [7:0]  cur_wd = 0;
reg [22:0] seq_pc = 23'h00_8000;
integer s_reads = 0, s_errs = 0, w_reads = 0, w_errs = 0, s_cycles = 0;
integer s_first = -1;                // edge in the cycle the word first appeared
integer s_hist [0:15];
integer w_first = -1;
integer w_hist [0:15];
reg running = 0;
initial for (i = 0; i < 16; i = i + 1) begin s_hist[i] = 0; w_hist[i] = 0; end

function [7:0] rom_byte(input [22:0] a);
    rom_byte = a[0] ? rom_word(a[22:1]) >> 8 : rom_word(a[22:1]);
endfunction
wire [7:0] port0_byte = cur_rom[0] ? cpu_port0[15:8] : cpu_port0[7:0];
wire [7:0] port1_byte = cur_wram[0] ? cpu_port1[15:8] : cpu_port1[7:0];

always @(posedge mclk) if (running) begin
    // first edge at which the right byte is visible (sampled pre-edge)
    if ((cyc_type == T_ROM || cyc_type == T_DMA) && s_first < 0 && cyc_pos > 0 && port0_byte == rom_byte(cur_rom))
        s_first <= cyc_pos;
    if (cyc_type == T_WRD && w_first < 0 && cyc_pos > 0 && port1_byte == wram_shadow[cur_wram])
        w_first <= cyc_pos;
    if (cyc_pos == cyc_len) begin
        // end of cycle: the CPU samples here
        s_cycles = s_cycles + 1;
        if (cyc_type == T_ROM || cyc_type == T_DMA) begin
`ifdef SDCMC_STABLE
            st_sample(0);
`endif
            s_reads = s_reads + 1;
            if (port0_byte !== rom_byte(cur_rom)) begin
                s_errs = s_errs + 1;
                if (s_errs < 10) $display("%0t S-CPU ROM %06x len %0d type %0d: got %02x want %02x", $time, cur_rom, cyc_len, cyc_type, port0_byte, rom_byte(cur_rom));
            end else
                s_hist[s_first >= 0 ? s_first : cyc_pos] = s_hist[s_first >= 0 ? s_first : cyc_pos] + 1;
        end
        if (cyc_type == T_WRD) begin
`ifdef SDCMC_STABLE
            st_sample(1);
`endif
            w_reads = w_reads + 1;
            if (port1_byte !== wram_shadow[cur_wram]) begin
                w_errs = w_errs + 1;
                if (w_errs < 10) $display("%0t S-CPU WRAM %05x: got %02x want %02x", $time, cur_wram, port1_byte, wram_shadow[cur_wram]);
            end else
                w_hist[w_first >= 0 ? w_first : cyc_pos] = w_hist[w_first >= 0 ? w_first : cyc_pos] + 1;
        end
        // next cycle
        cyc_pos <= 1;
        s_first <= -1; w_first <= -1;
        cyc_type = $urandom(seed) % 10;
        cyc_type = cyc_type < 5 ? T_ROM : cyc_type < 7 ? T_WRD : cyc_type < 8 ? T_WWR : cyc_type < 9 ? T_IO : T_DMA;
        cyc_len = cyc_type == T_DMA ? 8 : ($urandom(seed) % 4 == 0 ? 8 : ($urandom(seed) % 8 == 0 ? 12 : 6));
        ROM_CE_N <= 1; WRAM_CE_N <= 1; WRAM_RD_N <= 1; WRAM_WE_N <= 1;
        case (cyc_type)
        T_ROM, T_DMA: begin
            // code: mostly sequential; sometimes a far jump or data read
            if ($urandom(seed) % 6 == 0) seq_pc = {$urandom(seed)} % (1 << 21);
            else seq_pc = seq_pc + 1;
            cur_rom <= seq_pc;
            ROM_ADDR <= seq_pc; ROM_CE_N <= 0;
            if (cyc_type == T_DMA) begin       // A->B DMA to $2180: WRAM write mid-cycle
                cur_wram = {$urandom(seed)} % 131072;
                cur_wd = $urandom(seed);
                WRAM_ADDR <= cur_wram; WRAM_CE_N <= 0; WRAM_D <= cur_wd;
            end
        end
        T_WRD: begin                           // RD is a full-cycle strobe (CPURD_CYC_N)
            cur_wram = {$urandom(seed)} % 131072;
            WRAM_ADDR <= cur_wram; WRAM_CE_N <= 0; WRAM_RD_N <= 0;
        end
        T_WWR: begin
            cur_wram = {$urandom(seed)} % 131072;
            cur_wd = $urandom(seed);
            WRAM_ADDR <= cur_wram; WRAM_CE_N <= 0; WRAM_D <= cur_wd;
        end
        default: ;
        endcase
    end else begin
        cyc_pos <= cyc_pos + 1;
        // WRAM writes strobe after SYSCLKR to the cycle end: the CPU's from
        // its 3rd edge (CPU_MID_CLOCK=2), DMA's from its 4th (DMA_MID_CLOCK=3)
        if ((cyc_type == T_WWR && cyc_pos == 3) || (cyc_type == T_DMA && cyc_pos == 4)) begin
            WRAM_WE_N <= 0;
            wram_shadow[cur_wram] = cur_wd;
        end
    end
end

// ---- second master: SA-1-like reader on CPU2 ------------------------------
integer m2_reads = 0, m2_errs = 0, m2_lat = 0, m2_lat_min = 99, m2_lat_max = 0, m2_lat_sum = 0;
integer m2_gap = 0;
reg     m2_wait = 0;
reg [22:1] m2_tag = 0;
reg [22:1] m2_pc = 22'h08_0000;
always @(posedge mclk) if (running && scen != 0) begin
    if (m2_wait) begin
        m2_lat <= m2_lat + 1;
        if (cpu2_req_ack == cpu2_req) begin
            m2_wait <= 0;
            m2_reads = m2_reads + 1;
`ifdef SDCMC_STABLE
            m2_st_dly <= 2;
`endif
            if (cpu2_dout !== rom_word(m2_tag)) begin
                m2_errs = m2_errs + 1;
                if (m2_errs < 10) $display("%0t CPU2 %06x: got %04x want %04x", $time, {m2_tag, 1'b0}, cpu2_dout, rom_word(m2_tag));
            end
            m2_lat_sum = m2_lat_sum + m2_lat + 1;
            if (m2_lat + 1 > m2_lat_max) m2_lat_max = m2_lat + 1;
            if (m2_lat + 1 < m2_lat_min) m2_lat_min = m2_lat + 1;
            m2_gap <= scen == 1 ? 0 : ($urandom(seed) % 3 == 0 ? $urandom(seed) % 6 : 0);
        end
    end else if (m2_gap > 0)
        m2_gap <= m2_gap - 1;
    else begin
        if (scen == 1) m2_tag = {$urandom(seed)} % (1 << 20);
        else begin
            if ($urandom(seed) % 8 == 0) m2_pc = {$urandom(seed)} % (1 << 20);
            else m2_pc = m2_pc + 1;
            m2_tag = m2_pc;
        end
        cpu2_addr <= m2_tag;
        cpu2_req <= ~cpu2_req;
        m2_wait <= 1;
        m2_lat <= 0;
    end
end

// ---- BSRAM probe: one access every ~40 mclk --------------------------------
// Reads check the preloaded pattern; one access in four is a write (checked
// by later reads through a valid-bit shadow), which also fires the din/we
// request-window detectors below.
integer b_reads = 0, b_errs = 0, b_writes = 0, b_lat = 0, b_lat_max = 0, b_lat_sum = 0, b_gap = 10;
reg b_wait = 0;
reg [2:0] b_ack_sync = 0;
reg b_is_write = 0;
reg [7:0] b_wd = 0;
reg [8:0] b_tag = 0;
reg [8:0] b_nxt;
reg [7:0] b_wtmp;
reg b_wwr;
reg [7:0] bs_shadow [0:511];
reg bs_valid [0:511];
integer b_i;
initial begin for (b_i = 0; b_i < 512; b_i = b_i + 1) bs_valid[b_i] = 0; end
wire [7:0] bs_expect = bs_valid[b_tag] ? bs_shadow[b_tag] : (b_tag[0] ? b_tag[8:1] ^ 8'h33 : b_tag[8:1] ^ 8'hcc);
always @(posedge mclk) if (running) begin
    b_ack_sync <= {b_ack_sync[1:0], bs_req_ack};
    if (b_wait) begin
        b_lat <= b_lat + 1;
        // the ack toggles at CAS, the byte follows; sync it like snestang_top's bridge
        if (b_ack_sync[2] == bs_req && b_lat > 2) begin
            b_wait <= 0;
            if (b_is_write) begin
                bs_shadow[b_tag] <= b_wd;
                bs_valid[b_tag] <= 1;
                b_writes <= b_writes + 1;
            end else begin
                b_reads = b_reads + 1;
`ifdef SDCMC_STABLE
                st_sample(2);
`endif
                if (bsram_dout !== bs_expect) begin
                    b_errs = b_errs + 1;
                    if (b_errs < 10) $display("%0t BSRAM %05x: got %02x want %02x", $time, b_tag, bsram_dout, bs_expect);
                end
            end
            if (b_lat > b_lat_max) b_lat_max = b_lat;
            b_lat_sum = b_lat_sum + b_lat;
            b_gap <= 30 + $urandom(seed) % 20;
        end
    end else if (b_gap > 0)
        b_gap <= b_gap - 1;
    else begin
        b_nxt = {$urandom(seed)} % 512;
        bs_addr <= b_nxt;
        b_tag <= b_nxt;
        b_wtmp = $urandom(seed);
        b_wwr = $urandom(seed) % 4 == 0;
        bs_din <= b_wtmp;
        b_wd <= b_wtmp;
        b_is_write <= b_wwr;
        bs_we <= b_wwr;
        bs_req <= ~bs_req;
        b_wait <= 1;
        b_lat <= 0;
    end
end

`ifdef SDCMC_STABLE
// ---- ARAM master: SMP-like slow byte accesses on the ARAM lane ------------
// The SMP reads/writes ARAM at ~1 MHz through byte strobes (snestang_top.v
// drives aram_din={ARAM_D,ARAM_D} with aram_16=0, as here); its req toggle
// is fire-and-forget (aram_req_ack is unconnected at the top level). The
// controller serves one ARAM request per rotation (RAS at cycle2, CAS at
// cycle4, DATA at cycle1) and copies req into aram_req_ack at the serving
// cycle2, so the master waits for ack==req (seen at an mclk edge 2 fclk
// after the serving cycle2) and samples two mclk later: DATA lands at the
// serving cycle2 + 5 fclk and the next rotation overwrites aram_dout at +11,
// so +8 is inside the valid window. din/we are held until the sample, i.e.
// long past the serving cycle2 latch. A byte scoreboard with valid bits
// checks every read that follows a write.
integer a_reads = 0, a_errs = 0, a_writes = 0, a_gap = 8, a_state = 0, a_dly = 0;
reg [15:0] a_tag = 0;
reg [7:0]  a_wd = 0;
reg        a_is_write = 0;
reg [7:0]  aram_shadow [0:65535];
reg        aram_valid [0:65535];
integer a_i;
initial begin for (a_i = 0; a_i < 65536; a_i = a_i + 1) aram_valid[a_i] = 0; end
wire [7:0] aram_byte = a_tag[0] ? aram_dout[15:8] : aram_dout[7:0];
reg [15:0] a_nxt;
reg [7:0]  a_wtmp;
reg        a_wwr;
always @(posedge mclk) if (running) begin
    case (a_state)
    0: if (a_gap > 0)
        a_gap <= a_gap - 1;
    else begin
        // address/data and the toggle launch on the same mclk edge from
        // flops, like the top-level toggle-edge snapshots
        // (snestang_top.v aram_req/aram_addr_sd/aram_din_sd/aram_we_sd)
        a_nxt = {$urandom(seed)} % 65536;
        a_wtmp = $urandom(seed);
        a_wwr = $urandom(seed) % 3 == 0;
        aram_addr <= a_nxt;
        a_tag <= a_nxt;
        a_wd <= a_wtmp;
        a_is_write <= a_wwr;
        aram_din_r <= {a_wtmp, a_wtmp};
        aram_we_r <= a_wwr;
        aram_req <= ~aram_req;
        a_state <= 1;
    end
    1: if (dut.aram_req_ack == aram_req) begin
        a_dly <= 1;
        a_state <= 2;
    end
    2: if (a_dly == 0) begin
        if (a_is_write) begin
            aram_shadow[a_tag] <= a_wd;
            aram_valid[a_tag] <= 1;
            a_writes <= a_writes + 1;
        end else begin
            a_reads <= a_reads + 1;
            if (aram_valid[a_tag] && aram_byte !== aram_shadow[a_tag]) begin
                a_errs <= a_errs + 1;
                if (a_errs < 10) $display("%0t ARAM %04x: got %02x want %02x", $time, a_tag, aram_byte, aram_shadow[a_tag]);
            end
        end
        aram_we_r <= 0;
        a_gap <= 6 + $urandom(seed) % 24;
        a_state <= 0;
    end else
        a_dly <= a_dly - 1;
    endcase
end
`else
integer a_reads = 0, a_errs = 0, a_writes = 0;
`endif

`ifdef SDCMC_STABLE
// Multicycle-3 window proof. Each field below is an fclk launch that reaches
// mclk logic through the top data mux: sticky data regs (sampled value) plus
// the lane-select controls the STA paths launch from (ds/port/oe).
// Handshake toggles (acks, busy) are excluded: a late arrival there only
// costs a rotation, never corrupts.
//
// Method: one level-sensitive change detector per field timestamps its last
// transition ($time). At each mclk-domain sample the age in fclk periods is
// (now - t)/FCLK_U. No history arrays or cross-block counters: every
// variable has a single writer and all reads settle long before use, so no
// iverilog scheduling race can corrupt the verdict. A change exactly on the
// sampling edge has age 0 (the +1ns task delay) and is benign: it arrives
// after this sample. Verdict: violation iff 1 <= age <= 2 for a relevant
// field; age >= 3 is the budgeted window. Relevance is per lane and per
// consumer: ROM reads need p0, WRAM reads p1, CPU2 reads cpu2_dout (all
// sampled by slow mclk logic), and BSRAM bridge captures need the
// bsram_dout VALUE only (the bridge samples the controller output two mclk
// after the ack; the ds/port/oe selects cannot move that value with the
// read gate closed, sdram_cl2_2ch.v:257, so they are not relevant there).
// The SNES-side BSRAM selects are argued by construction in the report, not
// measured here: the tb has no SNES BSRAM bus master.
// Tags: 0 S-CPU ROM, 1 S-CPU WRAM, 2 BSRAM, 3 CPU2.
//
// FCLK_U is $time units per fclk: the tb drives fclk with #5 half-period
// under `timescale 1ns/1ps, so one period is 10ns. (Note: this iverilog
// build prints %0t scaled by 1000, i.e. in ps, but $time arithmetic is in
// the module units, ns. Do not "fix" FCLK_U from %0t output.)
localparam integer FCLK_U = 10;
time t_p0 = 0, t_p1 = 0, t_cpu2 = 0, t_bs = 0;
time t_aram = 0, t_ds = 0, t_port = 0, t_oe = 0;
integer c_p0 = 0, c_p1 = 0, c_cpu2 = 0, c_bs = 0;
integer c_aram = 0, c_ds = 0, c_port = 0, c_oe = 0;
always @(cpu_port0) begin t_p0 = $time; c_p0 = c_p0 + 1; end
always @(cpu_port1) begin t_p1 = $time; c_p1 = c_p1 + 1; end
`ifndef BASELINE
always @(cpu2_dout) begin t_cpu2 = $time; c_cpu2 = c_cpu2 + 1; end
`endif
always @(bsram_dout) begin t_bs = $time; c_bs = c_bs + 1; end
always @(aram_dout) begin t_aram = $time; c_aram = c_aram + 1; end
always @(dut.ds[0]) begin t_ds = $time; c_ds = c_ds + 1; end
always @(dut.port[0]) begin t_port = $time; c_port = c_port + 1; end
always @(dut.oe_latch[0]) begin t_oe = $time; c_oe = c_oe + 1; end
function integer age;
    input [63:0] t;
    input [63:0] now;
    begin
        age = (now - t) / FCLK_U;
    end
endfunction
integer st_samples = 0, st_viol = 0;
integer st_minage = 1000000;
integer st_tag_cnt [0:3];
integer st_tag_min [0:3];
initial begin
    st_tag_cnt[0] = 0; st_tag_cnt[1] = 0; st_tag_cnt[2] = 0; st_tag_cnt[3] = 0;
    st_tag_min[0] = 1000000; st_tag_min[1] = 1000000;
    st_tag_min[2] = 1000000; st_tag_min[3] = 1000000;
end
task st_sample;
    input integer tag;
    integer a0, a1, a2, a3, a4, a5, a6, a7, amin, now;
    begin
        #1;
        now = $time;
        st_samples = st_samples + 1;
        st_tag_cnt[tag] = st_tag_cnt[tag] + 1;
        a0 = age(t_p0, now); a1 = age(t_p1, now);
        a2 = age(t_cpu2, now); a3 = age(t_bs, now);
        a4 = age(t_aram, now); a5 = age(t_ds, now);
        a6 = age(t_port, now); a7 = age(t_oe, now);
        case (tag)
        0: amin = a0;
        1: amin = a1;
        2: amin = a3;
        3: amin = a2;
        default: amin = -1;
        endcase
        if (amin < st_minage) st_minage = amin;
        if (amin < st_tag_min[tag]) st_tag_min[tag] = amin;
        if (amin >= 0 && amin < 3) begin
            st_viol = st_viol + 1;
            if (st_viol <= 10)
                $display("%0t STABLE-VIOL tag=%0d agemin=%0d ages=%0d/%0d/%0d/%0d/%0d/%0d/%0d/%0d",
                         $time, tag, amin, a0, a1, a2, a3, a4, a5, a6, a7);
        end
    end
endtask
// CPU2 samples like the real consumer (sa1_rom_cache.v): 2 mclk after the
// ack is first seen, matching its 2FF synchroniser.
integer m2_st_dly = 0;
always @(posedge mclk) if (running) begin
    if (m2_st_dly > 0) begin
        m2_st_dly <= m2_st_dly - 1;
        if (m2_st_dly == 1) st_sample(3);
    end
end

// Request-window proof (mclk->fclk). Each field below is a controller input
// launched from mclk (snestang_top.v:419-471,524-551, sa1_rom_cache.v,
// cpu.v:783-786); the capture edges are the request latch at cycle[0] and
// the ARAM latch at cycle[2] (sdram_cl2_2ch.v:320-328,331-344). All launches
// happen on mclk edges and the rotation is phase-locked to mclk (lock
// counter below), so ages are phase-determined: 2 mod 3 on the request lane,
// 1 mod 3 on ARAM. Verdict for the SDC's setup-2 budget: no request-lane age
// 0 or 1. ARAM ages are measured, not gated: its first capture is 1 fclk
// after launch (see the report). Same-edge (age 0) would be a hold-side
// event and is counted separately.
// Phase lock: clkref (DOT_CLK_CE, 1 mclk every 4) re-syncs the rotation to
// cycle5 (:312-315); the 4-mclk period is a multiple of the 6-fclk rotation,
// so past startup the free-running rotation already shows cycle[4] (which
// rotates into 5 exactly as the resync asserts) and forcing 5 is a no-op.
// lock_corr counts resyncs that found anything else while running.
// RV inputs are dead on console138k (unconnected under MCU_BL616,
// snestang_top.v:719-721) and tied off here, as in the build.
time    q_t [0:15];
integer q_c [0:15];
integer q_min [0:15];
integer q_j;
initial begin
    for (q_j = 0; q_j < 16; q_j = q_j + 1) begin
        q_t[q_j] = 0; q_c[q_j] = 0; q_min[q_j] = 1000000;
    end
end
// request lane (captured at cycle[0]): 0 cpu_req 1 cpu_addr 2 cpu_din
// 3 cpu_we 4 cpu_ds 5 cpu_port 6 cpu2_req 7 cpu2_addr 8 bs_req 9 bs_addr
// 10 bs_din 11 bs_we. ARAM lane (captured at cycle[2]): 12 aram_req
// 13 aram_addr 14 aram_din 15 aram_we.
always @(cpu_req) begin q_t[0] = $time; q_c[0] = q_c[0] + 1; end
always @(cpu_addr) begin q_t[1] = $time; q_c[1] = q_c[1] + 1; end
always @(cpu_din) begin q_t[2] = $time; q_c[2] = q_c[2] + 1; end
always @(cpu_we) begin q_t[3] = $time; q_c[3] = q_c[3] + 1; end
always @(cpu_ds) begin q_t[4] = $time; q_c[4] = q_c[4] + 1; end
always @(cpu_port) begin q_t[5] = $time; q_c[5] = q_c[5] + 1; end
always @(cpu2_req) begin q_t[6] = $time; q_c[6] = q_c[6] + 1; end
always @(cpu2_addr) begin q_t[7] = $time; q_c[7] = q_c[7] + 1; end
always @(bs_req) begin q_t[8] = $time; q_c[8] = q_c[8] + 1; end
always @(bs_addr) begin q_t[9] = $time; q_c[9] = q_c[9] + 1; end
always @(bs_din) begin q_t[10] = $time; q_c[10] = q_c[10] + 1; end
always @(bs_we) begin q_t[11] = $time; q_c[11] = q_c[11] + 1; end
always @(aram_req) begin q_t[12] = $time; q_c[12] = q_c[12] + 1; end
always @(aram_addr) begin q_t[13] = $time; q_c[13] = q_c[13] + 1; end
always @(aram_din_r) begin q_t[14] = $time; q_c[14] = q_c[14] + 1; end
always @(aram_we_r) begin q_t[15] = $time; q_c[15] = q_c[15] + 1; end
integer rq_samples = 0, rq_e0 = 0, rq_v1 = 0, rq_v2 = 0, rq_min = 1000000;
integer ar_samples = 0, ar_e0 = 0, ar_v1 = 0, ar_min = 1000000;
integer lock_seen = 0, lock_corr = 0;
integer rq_now, rq_k, rq_a;
// The lock check reads pre-edge values, so no delay here; the lane sampling
// below needs the settled post-NBA rotation, hence its own delayed block.
always @(posedge fclk) if (running) begin
    if (dut.clkref & ~dut.clkref_r) begin
        lock_seen = lock_seen + 1;
        if (dut.cycle != 12'h010) begin
            lock_corr = lock_corr + 1;
            if (lock_corr <= 5)
                $display("%0t LOCK-CORR cyc=%b", $time, dut.cycle);
        end
    end
end
always @(posedge fclk) if (running) begin
    #1;
    if (dut.cycle[0]) begin
        rq_now = $time;
        rq_samples = rq_samples + 1;
        for (rq_k = 0; rq_k < 12; rq_k = rq_k + 1) begin
            rq_a = age(q_t[rq_k], rq_now);
            if (rq_a < q_min[rq_k]) q_min[rq_k] = rq_a;
            if (rq_a < rq_min) rq_min = rq_a;
            if (rq_a == 0) rq_e0 = rq_e0 + 1;
            else if (rq_a == 1) begin
                rq_v1 = rq_v1 + 1;
                if (rq_v1 <= 10)
                    $display("%0t RQ-VIOL field=%0d age=%0d", $time, rq_k, rq_a);
            end
            else if (rq_a == 2) rq_v2 = rq_v2 + 1;
        end
    end
    if (dut.cycle[2]) begin
        rq_now = $time;
        ar_samples = ar_samples + 1;
        for (rq_k = 12; rq_k < 16; rq_k = rq_k + 1) begin
            rq_a = age(q_t[rq_k], rq_now);
            if (rq_a < q_min[rq_k]) q_min[rq_k] = rq_a;
            if (rq_a < ar_min) ar_min = rq_a;
            if (rq_a == 0) ar_e0 = ar_e0 + 1;
            else if (rq_a == 1) ar_v1 = ar_v1 + 1;
        end
    end
end
`endif

// ---- trace for the identity check ------------------------------------------
always @(posedge fclk) if (trace && running)
    $fdisplay(tf, "%b %h %h %b %h %h %h %h %b",
        {sdram_ncs, sdram_nras, sdram_ncas, sdram_nwe}, sdram_a, sdram_ba, sdram_dqm,
        sdram_dq, cpu_port0, cpu_port1, bsram_dout, {cpu_req_ack, bs_req_ack});
`ifdef SDCMC_STABLE
// Internal trace for stability-violation triage (rotation vs sample timing).
integer tf2 = 0;
always @(posedge fclk) if (trace && running)
    $fdisplay(tf2, "%0t cyc=%b port=%0d ds=%b oe=%b p0=%h p1=%h cpu2=%h bs=%h bsreg=%h aram=%h ack=%b%b%b",
        $time, dut.cycle, dut.port[0], dut.ds[0], dut.oe_latch[0],
        cpu_port0, cpu_port1, cpu2_dout, bsram_dout, dut.bsram_dout_reg, aram_dout,
        dut.cpu_req_ack, dut.bsram_req_ack, cpu2_req_ack);
`endif

// ---- run --------------------------------------------------------------------
integer t, wbad;
initial begin
    if ($value$plusargs("SCEN=%d", scen)) ;
    if ($value$plusargs("CYCLES=%d", ncycles)) ;
    if ($value$plusargs("SEED=%d", seed)) ;
    if ($value$plusargs("PHASE=%d", phase)) ;
    cyc_len = 6 + phase;
    if ($test$plusargs("TRACE")) begin
        trace = 1;
        tf = $fopen("trace.txt", "w");
`ifdef SDCMC_STABLE
        tf2 = $fopen("trace_stable.txt", "w");
`endif
    end
    repeat (5) @(posedge mclk);
    resetn = 1;
    wait (!sdram_busy);
    repeat (20) @(posedge mclk);
    @(posedge mclk) running <= 1;
    wait (s_cycles >= ncycles);
    running <= 0;
    repeat (20) @(posedge mclk);
    // WRAM contents in the chip must match the shadow (every write landed)
    wbad = 0;
    for (i = 0; i < 131072; i = i + 1)
        if ((i[0] ? chip.mem[24'h3F_0000 + (i >> 1)][15:8] : chip.mem[24'h3F_0000 + (i >> 1)][7:0]) !== wram_shadow[i]) begin
            if (wbad < 5) $display("WRAM[%05x] = %02x, want %02x", i, i[0] ? chip.mem[24'h3F_0000 + (i >> 1)][15:8] : chip.mem[24'h3F_0000 + (i >> 1)][7:0], wram_shadow[i]);
            wbad = wbad + 1;
        end
    $display("scenario %0d: %0d S-CPU cycles", scen, s_cycles);
    $display("  S-CPU ROM reads %0d, errors %0d; WRAM reads %0d, errors %0d; WRAM cells wrong %0d",
             s_reads, s_errs, w_reads, w_errs, wbad);
    $write("  ROM word on port by cycle edge:");
    for (i = 0; i < 13; i = i + 1) $write(" %0d:%0d", i, s_hist[i]);
    $write("\n  WRAM byte on port by cycle edge:");
    for (i = 0; i < 13; i = i + 1) $write(" %0d:%0d", i, w_hist[i]);
    $write("\n");
    for (i = 12; i > 0 && s_hist[i] == 0; i = i - 1) ;
    $display("  S-CPU ROM latest edge %0d (deadline: edge 6 for a 6-mclk cycle)", i);
    for (t = 12; t > 0 && w_hist[t] == 0; t = t - 1) ;
    $display("  S-CPU WRAM latest edge %0d", t);
    if (scen != 0)
        $display("  CPU2 reads %0d, errors %0d, latency req->ack min %0d avg %0d.%02d max %0d mclk",
                 m2_reads, m2_errs, m2_lat_min, m2_lat_sum / (m2_reads ? m2_reads : 1),
                 (m2_lat_sum * 100 / (m2_reads ? m2_reads : 1)) % 100, m2_lat_max);
    $display("  BSRAM reads %0d, errors %0d, writes %0d, latency max %0d avg %0d mclk", b_reads, b_errs, b_writes, b_lat_max, b_lat_sum / (b_reads ? b_reads : 1));
    $display("  ARAM reads %0d, errors %0d, writes %0d", a_reads, a_errs, a_writes);
    $display("RESULT scen=%0d s_errs=%0d w_errs=%0d wram_bad=%0d m2_errs=%0d b_errs=%0d a_errs=%0d s_max=%0d w_max=%0d m2_max=%0d m2_reads=%0d a_reads=%0d",
             scen, s_errs, w_errs, wbad, m2_errs, b_errs, a_errs, i, t, m2_lat_max, m2_reads, a_reads);
`ifdef SDCMC_STABLE
    $display("STABLE scen=%0d samples=%0d viol=%0d minage=%0d tags=%0d/%0d/%0d/%0d tagmin=%0d/%0d/%0d/%0d",
             scen, st_samples, st_viol, st_minage,
             st_tag_cnt[0], st_tag_cnt[1], st_tag_cnt[2], st_tag_cnt[3],
             st_tag_min[0], st_tag_min[1], st_tag_min[2], st_tag_min[3]);
    $display("STABLE-DET p0=%0d p1=%0d cpu2=%0d bs=%0d aram=%0d ds=%0d port=%0d oe=%0d",
             c_p0, c_p1, c_cpu2, c_bs, c_aram, c_ds, c_port, c_oe);
    $display("RQSTABLE scen=%0d rq_samples=%0d rq_e0=%0d rq_v1=%0d rq_v2=%0d rq_min=%0d ar_samples=%0d ar_e0=%0d ar_v1=%0d ar_min=%0d lock_seen=%0d lock_corr=%0d",
             scen, rq_samples, rq_e0, rq_v1, rq_v2, rq_min,
             ar_samples, ar_e0, ar_v1, ar_min, lock_seen, lock_corr);
    $display("RQSTABLE-QMIN %0d/%0d/%0d/%0d/%0d/%0d/%0d/%0d/%0d/%0d/%0d/%0d/%0d/%0d/%0d/%0d",
             q_min[0], q_min[1], q_min[2], q_min[3], q_min[4], q_min[5],
             q_min[6], q_min[7], q_min[8], q_min[9], q_min[10], q_min[11],
             q_min[12], q_min[13], q_min[14], q_min[15]);
    $display("RQDET creq=%0d caddr=%0d cdin=%0d cwe=%0d cds=%0d cport=%0d m2req=%0d m2addr=%0d breq=%0d baddr=%0d bdin=%0d bwe=%0d areq=%0d aaddr=%0d adin=%0d awe=%0d",
             q_c[0], q_c[1], q_c[2], q_c[3], q_c[4], q_c[5],
             q_c[6], q_c[7], q_c[8], q_c[9], q_c[10], q_c[11],
             q_c[12], q_c[13], q_c[14], q_c[15]);
`endif
    if (trace) $fclose(tf);
`ifdef SDCMC_STABLE
    if (trace) $fclose(tf2);
`endif
    $finish;
end

endmodule
