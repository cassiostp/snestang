// Can snestang's SDRAM ROM port serve the CX4?  The real request logic of snestang_top.v (the ROM and
// WRAM edge detectors, extracted from the source at build time, see run.sh) in front of the real
// sdram_snes controller and a behavioural SDRAM chip, with the CX4's ROM cache-fill cadence on the
// CPU2 lane (through the real sa1_rom_cache word cache, as the core builds it) and, optionally,
// S-CPU WRAM accesses on the CPU lane.
//
// The CX4 model is the patched chip's cadence (CEGen's 2 MHz / 2.147727 MHz clock enable, then
// CACHE_WAIT_CNT counting to WS1, held while ROM_WAIT is up: CX4.vhd cache process): it changes the
// ROM address on one clock-enable tick and samples the data WS1+1 ticks later, or later if the word
// has not arrived. The S-CPU model makes a SlowROM cycle (8 master clocks) every time, reading or
// writing one of 32 WRAM bytes with probability +wram=<percent>. Every WRAM read is checked
// against what was written.
//
// +ws=<n>      CX4 wait state WS1 (default 3, the chip's reset value)
// +steps=<n>   CX4 byte fetches to run
// +wram=<pct>  percentage of S-CPU cycles that access WRAM (default 0)
// +phase=<n>   master clocks to delay the dot clock by (default 0)
// +verbose     print every fetch that was wrong

`timescale 1ps/1ps

module tb_port;

// ---- clocks: fclk = 3 x mclk, rising edges coincident (sdram_cl2_2ch.v header) ----
reg mclk = 0, fclk = 0;
always #7757 fclk = ~fclk;
always #23271 mclk = ~mclk;

// ---- DOT_CLK_CE (the controller's clkref): one mclk wide, every 4 master clocks, with the two
// 6-clock dots of an NTSC line (1364 = 338*4 + 2*6)
reg dot_ce = 0;
integer dot_cnt = 0, dot_n = 0, dot_delay = 0;
always @(posedge mclk) begin
    dot_ce <= 0;
    if (dot_delay > 0) dot_delay <= dot_delay - 1;
    else if (dot_cnt == 0) begin
        dot_ce <= 1;
        dot_cnt <= ((dot_n == 322) || (dot_n == 326)) ? 5 : 3;
        dot_n <= (dot_n == 339) ? 0 : dot_n + 1;
    end else
        dot_cnt <= dot_cnt - 1;
end

// ---- the part of snestang_top.v under test -------------------------------------------------
reg         resetn = 0;
reg         loading = 0, header_finished = 1, loader_do_valid = 0;
reg  [22:0] loader_addr = 0;
reg   [7:0] loader_do = 0, loader_do_r = 0;
reg         ROM_CE_N = 1;
reg  [23:0] ROM_ADDR = 0;
wire        ROM_WORD = 1'b0;                                // CX4Map: ROM_WORD <= '0'
wire [22:0] rom_addr = loading ? loader_addr : ROM_ADDR[22:0];
reg  [22:0] rom_addr_sd = 0;                                // flip-flops power up as 0 on the FPGA
reg  [16:0] WRAM_ADDR = 0, wram_addr_sd = 0;
reg   [7:0] WRAM_D = 0;
reg         wram_rd = 0, wram_wr = 0, wram_rd_r = 0, wram_wr_r = 0;
reg         scpu_wram_sel = 0;

wire [15:0] cpu_port0, cpu_port1;
reg         cpu_port;
reg         cpu_req = 0;
reg   [1:0] cpu_ds;
reg  [15:0] cpu_din;
reg  [22:0] cpu_addr;
reg         cpu_we;

// CX4 owns the ROM bus while it runs: its fetches go through the CPU2 word
// cache, the S-CPU lane keeps WRAM (top_req.vh suppresses the CPU-lane ROM
// fetch while cx4_owns_rom is up, exactly as snestang_top.v does).
reg         cx4_run = 0;
wire        cx4_rom_req = cx4_run;                          // always fetching ROM while running
wire        cx4_mode = 1'b1;
wire        cx4_owns_rom = cx4_mode & cx4_rom_req;
wire        gsu_owns_rom = 1'b0;   // no GSU in this bench (its CPU2 lane is sim/gsu_boot's)
wire [15:0] cx4_rom_q;
wire        cx4_rom_wait;
wire [15:0] rom_word = cx4_owns_rom ? cx4_rom_q : cpu_port0;
wire [15:0] ROM_Q = (ROM_WORD || ~ROM_ADDR[0]) ? rom_word : { rom_word[7:0], rom_word[15:8] };
wire  [7:0] WRAM_SD_Q = WRAM_ADDR[0] ? cpu_port1[15:8] : cpu_port1[7:0];

always @(posedge mclk) begin
    if (~resetn) begin
    end else begin
`include "top_req.vh"
    end
end

// The CX4's word cache (the real sa1_rom_cache, second instance as built).
// While the CX4 owns the bus rom_addr is its fetch address.
wire [22:1] cpu2_addr;
wire        cpu2_req;
wire        cpu2_req_ack;
wire [15:0] cpu2_dout;
sa1_rom_cache #(.QUALIFY_WAIT(1)) cx4_cache (
    .mclk(mclk), .resetn(resetn), .active(~loading),
    .rom_addr(rom_addr), .rom_req(cx4_rom_req),
    .rom_q(cx4_rom_q), .rom_wait(cx4_rom_wait),
    .cpu2_addr(cpu2_addr), .cpu2_req(cpu2_req),
    .cpu2_req_ack(cpu2_req_ack), .cpu2_dout(cpu2_dout)
);

wire sdram_busy;
wire [15:0] sdram_dq;
wire [12:0] sdram_a;
wire [1:0]  sdram_ba, sdram_dqm;
wire        sdram_ncs, sdram_nwe, sdram_nras, sdram_ncas, sdram_cke;

sdram_snes sdram (
    .clk(fclk), .mclk(mclk), .clkref(dot_ce), .resetn(resetn), .busy(sdram_busy),
    .SDRAM_DQ(sdram_dq), .SDRAM_A(sdram_a), .SDRAM_BA(sdram_ba),
    .SDRAM_nCS(sdram_ncs), .SDRAM_nWE(sdram_nwe), .SDRAM_nRAS(sdram_nras),
    .SDRAM_nCAS(sdram_ncas), .SDRAM_CKE(sdram_cke), .SDRAM_DQM(sdram_dqm),
    .cpu_addr(cpu_addr[22:1]), .cpu_din(cpu_din), .cpu_port(cpu_port),
    .cpu_port0(cpu_port0), .cpu_port1(cpu_port1), .cpu_req(cpu_req),
    .cpu_req_ack(), .cpu_we(cpu_we), .cpu_ds(cpu_ds),
    .cpu2_addr(cpu2_addr), .cpu2_dout(cpu2_dout),
    .cpu2_req(cpu2_req), .cpu2_req_ack(cpu2_req_ack),
    .bsram_addr(20'h0), .bsram_dout(), .bsram_din(8'h0),
    .bsram_req(1'b0), .bsram_req_ack(), .bsram_we(1'b0),
    .aram_16(1'b0), .aram_addr(16'h0), .aram_din(16'h0),
    .aram_dout(), .aram_req(1'b0), .aram_req_ack(), .aram_we(1'b0),
    .rv_addr(22'h0), .rv_din(16'h0), .rv_ds(2'b00), .rv_dout(),
    .rv_req(1'b0), .rv_req_ack(), .rv_we(1'b0)
);

// Gowin powers every flip-flop up as 0; iverilog starts them at x, so the controller's ack outputs
// (which its request test xors with the host's toggles) are cleared here
initial begin
    sdram.cpu_req_ack = 0;
    sdram.cpu2_req_ack = 0;
    sdram.bsram_req_ack = 0;
    sdram.aram_req_ack = 0;
    sdram.rv_req_ack = 0;
end

sdram_chip chip (
    .fclk(fclk), .A(sdram_a), .BA(sdram_ba), .DQM(sdram_dqm),
    .nCS(sdram_ncs), .nWE(sdram_nwe), .nRAS(sdram_nras), .nCAS(sdram_ncas),
    .SDRAM_DQ(sdram_dq)
);

// ---- a CPU-lane request that arrives while the controller still owes an ack is lost:
// two toggles of cpu_req in the same acceptance window cancel (the CPU lane has no ack).
// The CX4 no longer uses this lane, so ROM+WRAM coincidences are gone by construction.
reg cpu_req_d = 0;
integer lost = 0, req_total = 0;
always @(posedge mclk) begin
    cpu_req_d <= cpu_req;
    if (cpu_req != cpu_req_d) begin
        req_total <= req_total + 1;
        if (sdram.cpu_req_ack != cpu_req_d) lost <= lost + 1;   // previous toggle not yet acknowledged
    end
end

// ---- the CPU2 lane is acked (the cache waits), so nothing is lost there; count to prove it
reg cpu2_req_d = 0;
integer lost2 = 0, req_total2 = 0;
always @(posedge mclk) begin
    cpu2_req_d <= cpu2_req;
    if (cpu2_req != cpu2_req_d) begin
        req_total2 <= req_total2 + 1;
        if (cpu2_req_ack != cpu2_req_d) lost2 <= lost2 + 1;
    end
end

// ---- the cartridge image: 16 KB, no two neighbouring bytes alike
function [7:0] pat(input [22:0] a);
    pat = (a * 29 + 1 + (a >> 8) * 3) & 8'hFF;
endfunction

task load_rom(input integer n);
    integer i;
    begin
        @(posedge mclk); #100;
        loading = 1;
        loader_addr = 0;
        repeat (4) @(posedge mclk);
        #100;
        for (i = 0; i < n; i = i + 1) begin
            loader_do = pat(i);
            loader_do_valid = 1;
            @(posedge mclk); #100;
            loader_do_valid = 0;
            loader_do_r = loader_do;
            loader_addr = loader_addr + 1;
            @(posedge mclk); #100;           // a 16-bit word every 4 master clocks: the controller takes one per 2
        end
        repeat (8) @(posedge mclk);
        #100;
        loading = 0;
        repeat (8) @(posedge mclk);
    end
endtask

// ---- CX4 model (patched chip: wait counters hold while ROM_WAIT is up) -----------------------
integer WS1 = 3;
integer steps = 4000;
reg [31:0] clk_sum = 0;
reg ce = 0;
always @(negedge mclk) begin                  // CEGen.vhd: falling_edge(CLK)
    ce <= 0;
    if (cx4_run) begin
        clk_sum = clk_sum + 2000000;
        if (clk_sum >= 2147727) begin
            clk_sum = clk_sum - 2147727;
            ce <= 1;
        end
    end
end

integer cwc = 0, fetched = 0, bad = 0;
integer addr_change_t = 0;                    // time of the last address change, in fclk ticks
integer fclk_ticks = 0;
always @(posedge fclk) fclk_ticks <= fclk_ticks + 1;

reg [15:0] lat_hist [0:63];                   // arrival time after the address change, in fclk ticks
integer lat_max = 0, lat_n = 0, lat_never = 0;
reg arrived = 0;
reg verbose = 0;
integer stalls = 0;

always @(posedge mclk) begin
    if (cx4_run && ce) begin
        if (cx4_rom_wait) begin
            // CX4.vhd (patched): the wait counter holds until the word arrives
            stalls <= stalls + 1;
        end else if (cwc == WS1) begin
            // CACHE_DI <= BUS_DI on this tick, the address moves on
            if (ROM_Q[7:0] !== pat(ROM_ADDR[22:0])) begin
                bad <= bad + 1;
                if (verbose) $display("bad fetch at %0t: addr %h got %h want %h", $time, ROM_ADDR[22:0], ROM_Q[7:0], pat(ROM_ADDR[22:0]));
            end
            fetched <= fetched + 1;
            if (!arrived) lat_never <= lat_never + 1;
            ROM_ADDR <= (ROM_ADDR + 1) & 24'h003FFF;
            addr_change_t <= fclk_ticks + 1;
            arrived <= 0;
            cwc <= 0;
        end else
            cwc <= cwc + 1;
    end
end

// arrival of the right byte, in fclk ticks after the CX4 moved to a new address
integer d;
always @(posedge fclk) begin
    if (cx4_run && !arrived && ROM_Q[7:0] === pat(ROM_ADDR[22:0]) && fclk_ticks > addr_change_t) begin
        arrived <= 1;
        d = fclk_ticks - addr_change_t;
        lat_n <= lat_n + 1;
        // a larger gap is a much later coincidence with the pattern, not this fetch arriving
        if (d < 64) begin
            if (d > lat_max) lat_max <= d;
            lat_hist[d] <= lat_hist[d] + 1;
        end
    end
end

// ---- S-CPU model: SlowROM cycles of 8 master clocks, WRAM reads/writes at the given rate -------
integer wram_pct = 0;
reg sc_stop = 0;                            // set at run end: finish the cycle, then stay idle
reg [7:0] shadow [0:31];
reg       valid  [0:31];
integer wram_reads = 0, wram_bad = 0, wram_writes = 0;
integer sc_cnt = 0;
reg [4:0] sc_a;
reg       sc_wr, sc_active;
reg [7:0] sc_d;

always @(posedge mclk) begin
    if (cx4_run) begin
        sc_cnt <= (sc_cnt == 7) ? 0 : sc_cnt + 1;
        case (sc_cnt)
        0: begin
            sc_active = !sc_stop && (($urandom % 100) < wram_pct);
            sc_a = $urandom;
            sc_wr = ($urandom % 3) == 0 || !valid[sc_a];
            sc_d = $urandom;
            scpu_wram_sel <= sc_active;
            if (sc_active) begin
                WRAM_ADDR <= {12'h0, sc_a};
                WRAM_D <= sc_d;
            end
        end
        1: if (sc_active) begin
            if (sc_wr) wram_wr <= 1; else wram_rd <= 1;
        end
        7: begin
            if (sc_active && !sc_wr) begin
                wram_reads <= wram_reads + 1;
                if (WRAM_SD_Q !== shadow[sc_a]) begin
                    wram_bad <= wram_bad + 1;
                    if (verbose) $display("bad WRAM read at %0t: %h got %h want %h", $time, sc_a, WRAM_SD_Q, shadow[sc_a]);
                end
            end
            if (sc_active && sc_wr) begin
                shadow[sc_a] = sc_d;
                valid[sc_a] = 1;
                wram_writes <= wram_writes + 1;
            end
        end
        endcase
        if (sc_cnt == 6) begin wram_wr <= 0; wram_rd <= 0; end
    end
end

integer i;
reg [22:0] last_rom;
initial begin
    if (!$value$plusargs("ws=%d", WS1)) WS1 = 3;
    if (!$value$plusargs("steps=%d", steps)) steps = 4000;
    if (!$value$plusargs("wram=%d", wram_pct)) wram_pct = 0;
    if (!$value$plusargs("phase=%d", dot_delay)) dot_delay = 0;
    verbose = $test$plusargs("verbose");
    for (i = 0; i < 64; i = i + 1) lat_hist[i] = 0;
    for (i = 0; i < 32; i = i + 1) valid[i] = 0;

    repeat (20) @(posedge mclk);
    resetn = 1;
    wait (sdram_busy == 0);
    repeat (50) @(posedge mclk);

    load_rom(16384);
    // the first reads after loading: a spot check of the image (CPU lane, CX4 idle)
    ROM_CE_N = 0;
    for (i = 0; i < 6; i = i + 1) begin
        #100; ROM_ADDR = 24'h000100 + i * 9;
        repeat (20) @(posedge mclk);
        if (ROM_Q[7:0] !== pat(ROM_ADDR[22:0])) $display("FAIL: image check at %h: got %h want %h", ROM_ADDR, ROM_Q[7:0], pat(ROM_ADDR[22:0]));
    end

    // The mapper may expose a ROM alias during an A-bus WRAM cycle.
    // It must not consume a ROM request or prevent the next real fetch.
    for (i = 0; i < 32; i = i + 1) begin
        #100;
        last_rom = rom_addr_sd;
        scpu_wram_sel = 1;
        ROM_ADDR = 24'h001000 + i * 3;
        WRAM_ADDR = i;
        WRAM_D = pat(i);
        wram_wr = 1;
        repeat (8) @(posedge mclk);
        #100;
        if (rom_addr_sd !== last_rom) $fatal(1, "WRAM alias issued a ROM fetch");
        wram_wr = 0;
        wram_rd = 1;
        repeat (8) @(posedge mclk);
        #100;
        if (WRAM_SD_Q !== pat(i)) $fatal(1, "WRAM read after write failed");
        wram_rd = 0;
        scpu_wram_sel = 0;
        repeat (8) @(posedge mclk);
        #100;
        if (ROM_Q[7:0] !== pat(ROM_ADDR[22:0])) $fatal(1, "Real ROM fetch after WRAM failed");
    end

    // A B-bus WRAM write does not select A-bus WRAM. ROM prefetch must
    // remain enabled even while that write strobe is high.
    #100; wram_wr = 1; scpu_wram_sel = 0;
    repeat (8) @(posedge mclk);
    #100; ROM_ADDR = 24'h002101;
    repeat (8) @(posedge mclk);
    #100;
    if (ROM_Q[7:0] !== pat(ROM_ADDR[22:0])) $fatal(1, "B-bus write masked ROM fetch");
    wram_wr = 0;
    repeat (8) @(posedge mclk);
    $display("REQUEST SELECT: 97 checks PASS");

    // WRAM must hold the shadow before the run
    ROM_ADDR = 24'h000000;
    ROM_CE_N = 0;
    cx4_run = 1;
    wait (fetched >= steps);
    // Drain like a live S-CPU at bus handover: no new accesses, one full
    // idle SlowROM cycle, lane acked, and only then release the bus
    // (dropping cx4_run fires one CPU-lane ROM re-fetch). Halting the model
    // mid-cycle here used to collide that re-fetch with the last WRAM
    // toggle and count a lost request no running game could produce.
    sc_stop = 1;
    repeat (16) @(posedge mclk);
    for (i = 0; i < 64 && cpu_req != sdram.cpu_req_ack; i = i + 1) @(posedge mclk);
    cx4_run = 0;
    repeat (20) @(posedge mclk);

    $display("WS1=%0d wram=%0d%%: %0d CX4 fetches, %0d wrong (%0d%%); latest arrival %0d fclk ticks after the address (%0d never in time); wait stalls %0d",
             WS1, wram_pct, fetched, bad, (bad * 100) / fetched, lat_max, lat_never, stalls);
    $display("   arrival histogram (fclk ticks = 1/3 master clock):");
    for (i = 0; i < 24; i = i + 1)
        if (lat_hist[i] != 0) $display("     %2d (%0d.%0d mclk): %0d", i, i / 3, (i % 3) * 33 / 10, lat_hist[i]);
    $display("   S-CPU WRAM reads: %0d, wrong: %0d; CPU-lane requests: %0d, lost: %0d; CPU2 requests: %0d, lost: %0d",
             wram_reads, wram_bad, req_total, lost, req_total2, lost2);
    if (bad !== 0 || lost !== 0 || lost2 !== 0 || wram_bad !== 0) $fatal(1, "RESULT: FAIL");
    else $display("RESULT: PASS");
    $finish;
end

initial begin
    repeat (120) #1000000000;     // 120 ms of simulated time
    $display("TIMEOUT");
    $finish;
end

endmodule
