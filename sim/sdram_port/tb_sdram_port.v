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
    .aram_16(1'b1), .aram_addr(aram_addr), .aram_din(16'h0),
    .aram_dout(aram_dout), .aram_req(aram_req), .aram_req_ack(), .aram_we(1'b0),
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
            s_reads = s_reads + 1;
            if (port0_byte !== rom_byte(cur_rom)) begin
                s_errs = s_errs + 1;
                if (s_errs < 10) $display("%0t S-CPU ROM %06x len %0d type %0d: got %02x want %02x", $time, cur_rom, cyc_len, cyc_type, port0_byte, rom_byte(cur_rom));
            end else
                s_hist[s_first >= 0 ? s_first : cyc_pos] = s_hist[s_first >= 0 ? s_first : cyc_pos] + 1;
        end
        if (cyc_type == T_WRD) begin
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

// ---- BSRAM probe: one read every ~40 mclk ---------------------------------
integer b_reads = 0, b_errs = 0, b_lat = 0, b_lat_max = 0, b_lat_sum = 0, b_gap = 10;
reg b_wait = 0;
reg [2:0] b_ack_sync = 0;
always @(posedge mclk) if (running) begin
    b_ack_sync <= {b_ack_sync[1:0], bs_req_ack};
    if (b_wait) begin
        b_lat <= b_lat + 1;
        // the ack toggles at CAS, the byte follows; sync it like snestang_top's bridge
        if (b_ack_sync[2] == bs_req && b_lat > 2) begin
            b_wait <= 0;
            b_reads = b_reads + 1;
            if (bsram_dout !== (bs_addr[0] ? bs_addr[8:1] ^ 8'h33 : bs_addr[8:1] ^ 8'hcc)) begin
                b_errs = b_errs + 1;
                if (b_errs < 10) $display("%0t BSRAM %05x: got %02x", $time, bs_addr, bsram_dout);
            end
            if (b_lat > b_lat_max) b_lat_max = b_lat;
            b_lat_sum = b_lat_sum + b_lat;
            b_gap <= 30 + $urandom(seed) % 20;
        end
    end else if (b_gap > 0)
        b_gap <= b_gap - 1;
    else begin
        bs_addr <= {$urandom(seed)} % 512;
        bs_req <= ~bs_req;
        b_wait <= 1;
        b_lat <= 0;
    end
end

// ---- trace for the identity check ------------------------------------------
always @(posedge fclk) if (trace && running)
    $fdisplay(tf, "%b %h %h %b %h %h %h %h %b",
        {sdram_ncs, sdram_nras, sdram_ncas, sdram_nwe}, sdram_a, sdram_ba, sdram_dqm,
        sdram_dq, cpu_port0, cpu_port1, bsram_dout, {cpu_req_ack, bs_req_ack});

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
    $display("  BSRAM reads %0d, errors %0d, latency max %0d avg %0d mclk", b_reads, b_errs, b_lat_max, b_lat_sum / (b_reads ? b_reads : 1));
    $display("RESULT scen=%0d s_errs=%0d w_errs=%0d wram_bad=%0d m2_errs=%0d b_errs=%0d s_max=%0d w_max=%0d m2_max=%0d m2_reads=%0d",
             scen, s_errs, w_errs, wbad, m2_errs, b_errs, i, t, m2_lat_max, m2_reads);
    if (trace) $fclose(tf);
    $finish;
end

endmodule
