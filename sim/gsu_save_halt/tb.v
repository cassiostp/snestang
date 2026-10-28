`timescale 1ns/1ps
// Directed bench: save-channel traffic slipping into enable-low windows
// (firmware pause / per-frame HDMI halt) against GSU and S-CPU BSRAM
// accesses that cross those windows. TangCore issue #71.
//
// The bridge is extracted verbatim from src/snestang_top.v (the
// ../bsram_bridge extractor, bs_save_allow as a port; here it is driven
// with the top's gate ~enable & (pause | ~loaded)). The SDRAM
// controller is the fixed-delay model from sim/bsram_bridge; DELAY is
// sweepable.
//
// The GSU master models the output equations of src/chip/GSU/GSU.v:
// RAM_ACCESS_CNT countdown (RAM_CYCLES 3 at CLS=1, 1 otherwise), the
// negedge-sampled EN (GSU.v:399), RAM_WAIT holding every CNT==0
// completion, and the combinational RAM_CE_N/RAM_WE_N including the
// ~ENABLE forcing (CE asserted, WE deasserted, GSU.v:1523-1533).
// The S-CPU master presents a read and samples BSRAM_Q 5 enabled
// mclk later (the fixed sample point measured for issue #65), with no
// wait input, as in the real core.
module tb;
reg clk = 0;
always #5 clk = ~clk;

// ---- bridge pins -------------------------------------------------
reg gsu_mode = 1, sa1_mode = 0;
wire owner;                       // GSU_RAM_REQ into the bridge
reg [7:0] rom_type = 8'h70;
reg [19:0] pin_addr = 0;
reg [7:0] pin_din = 0;
reg pin_ce = 1, pin_rd = 1, pin_we = 1;
reg [17:0] sv_addr_r = 0;
reg [7:0] sv_din_r = 0;
reg sv_req_r = 0, sv_rreq_r = 0;
reg ack = 0;
reg [7:0] dout = 0;
wire [7:0] q;
reg enable_q = 1;                 // snestang_top's registered enable
reg pause_q = 0, loaded_q = 1;    // core_config[17] pause, loaded
wire bs_save_allow = ~enable_q & (pause_q | ~loaded_q);   // the top gate
bridge dut(clk, gsu_mode, sa1_mode, owner, rom_type, pin_addr, pin_din,
           pin_ce, pin_rd, pin_we, sv_addr_r, sv_din_r, sv_req_r, sv_rreq_r,
           ack, dout, q, bs_save_allow, enable_q);

// ---- SDRAM controller model (as sim/bsram_bridge) ----------------
reg [7:0] mem[0:131071];          // SDRAM BSRAM image
reg [7:0] gmem[0:131071];         // golden logical image
integer delaymax = 3, delay = 0, requests = 0;
always @(posedge clk) begin
    if (dut.bs_req_tog != ack) begin
        if (delay == delaymax) begin
            if (dut.bs_we_r) mem[dut.bs_addr_r] <= dut.bs_din_r;
            else dout <= mem[dut.bs_addr_r];
            ack <= dut.bs_req_tog; delay <= 0; requests <= requests + 1;
        end else delay <= delay + 1;
    end
end

// ---- enable / halt sequencer (enable is a posedge reg in the top) -
// Two window kinds: the per-frame halt (win_pause=0: enable low, pause
// bit clear, fixed length) and the firmware pause (win_pause=1: pause
// bit set; with halt_wait_idle the window lasts until the pending
// save toggle has acked, as the firmware's reply-waited fetches do).
integer cyc = 0;
integer halt_at = -1, halt_len = 0;
reg win_pause = 0, halt_wait_idle = 0;
wire stream_busy_h;               // assigned at the streamer below
reg win_on = 0;
wire in_window = win_on;
always @(posedge clk) begin
    cyc <= cyc + 1;
    if (halt_at >= 0 && cyc == halt_at)
        win_on <= 1;
    else if (win_on && cyc >= halt_at + halt_len &&
             !(halt_wait_idle && stream_busy_h))
        win_on <= 0;              // latched off: enable rises for good
    enable_q <= !win_on;
    pause_q <= win_on && win_pause;
end

// ---- GSU master model --------------------------------------------
localparam ST_IDLE = 0, ST_LOAD = 1, ST_SAVE = 2, ST_PCF = 3;
reg [1:0] gst = ST_IDLE;
reg [2:0] gcnt = 1;
reg gbytes = 0, gword = 0, pcf_rw = 0, pcf_phase = 0;
reg [16:0] ga = 0, pcf_a = 0;
reg [15:0] gdata = 0;
reg [7:0] pcf_rd = 0;
reg [16:0] pc_fetch = 17'h01234;  // {PBR[0],R15} stand-in while IDLE
reg speed = 1;                    // CLS: 1 -> RAM_CYCLES 3
wire [2:0] ram_cycles = speed ? 3'd3 : 3'd1;
reg clk_ce = 0, gen = 0;
reg gsu_active = 1;               // GSU_MEM_ACCESS & RAN
assign owner = gsu_active;
always @(posedge clk) if (enable_q) clk_ce <= ~clk_ce | speed;
always @(negedge clk) gen <= enable_q & gsu_active & clk_ce;

// command interface: tb sets at negedge, master consumes in IDLE
reg cmd_pend = 0;
reg [1:0] cmd_kind = ST_LOAD;
reg [16:0] cmd_addr = 0;
reg [15:0] cmd_data = 0;
reg cmd_word = 0;
reg done_flag = 0;
reg [15:0] cap_data = 0;
reg [7:0] cap_pcf = 0;

always @(posedge clk) begin
    if (gen) begin
        case (gst)
        ST_IDLE: begin
            if (pcf_phase) begin
                gcnt <= ram_cycles; gst <= ST_PCF;
            end else if (cmd_pend) begin
                cmd_pend <= 0;
                ga <= cmd_addr; gdata <= cmd_data; gword <= cmd_word;
                gbytes <= 0; gcnt <= ram_cycles;
                gst <= cmd_kind;
                if (cmd_kind == ST_PCF) begin pcf_a <= cmd_addr; pcf_rw <= 0; end
            end
        end
        ST_LOAD: begin
            if (gcnt == 0) begin
                if (!dut.gsu_ram_wait) begin
                    gcnt <= ram_cycles; gbytes <= 1;
                    if (!gbytes) cap_data[7:0] <= q;
                    else cap_data[15:8] <= q;
                    if (gbytes == gword) begin gst <= ST_IDLE; done_flag <= 1; end
                end
            end else gcnt <= gcnt - 1;
        end
        ST_SAVE: begin
            if (gcnt == 0) begin
                if (!dut.gsu_ram_wait) begin
                    gcnt <= ram_cycles; gbytes <= 1;
                    if (gbytes == gword) begin gst <= ST_IDLE; done_flag <= 1; end
                end
            end else gcnt <= gcnt - 1;
        end
        ST_PCF: begin
            if (gcnt == 0) begin
                if (!dut.gsu_ram_wait) begin
                    gst <= ST_IDLE;
                    if (!pcf_rw) begin
                        pcf_rd <= q; cap_pcf <= q; pcf_rw <= 1; pcf_phase <= 1;
                    end else begin
                        pcf_phase <= 0; done_flag <= 1;
                    end
                end
            end else gcnt <= gcnt - 1;
        end
        default: gst <= ST_IDLE;
        endcase
    end
end

// GSU combinational RAM bus (GSU.v:1510-1533, owner case)
wire [16:0] g_ram_a = (gst == ST_LOAD || gst == ST_SAVE) ?
                      {ga[16], ga[15:1], ga[0] ^ gbytes} :
                      (gst == ST_PCF) ? pcf_a : pc_fetch;
wire g_ce_n = ~enable_q ? 1'b0 :
              (gst == ST_LOAD || gst == ST_SAVE || gst == ST_PCF) ? 1'b0 : 1'b1;
wire g_we_n = ~enable_q ? 1'b1 :
              (gst == ST_SAVE && gcnt == 0) ? 1'b0 :
              (gst == ST_PCF && gcnt == 0) ? ~pcf_rw : 1'b1;
wire [7:0] g_dout = (gst == ST_SAVE) ? (gbytes ? gdata[15:8] : gdata[7:0]) :
                    (gst == ST_PCF) ? (pcf_rd ^ 8'hFF) : 8'h00;

// ---- S-CPU pins (driven by tasks when gsu_active=0) ---------------
reg [19:0] s_addr = 0;
reg [7:0] s_din = 0;
reg s_ce = 1, s_rd = 1, s_we = 1;

always @* begin
    if (gsu_active) begin
        pin_addr = {3'b000, g_ram_a};
        pin_din = g_dout;
        pin_ce = g_ce_n;
        pin_rd = 1'b1;            // CPURD_CYC_N: idle while GSU owns RAM
        pin_we = g_we_n;
    end else begin
        pin_addr = s_addr; pin_din = s_din;
        // GSU.v forces CE on and WE off under ~ENABLE in GSU carts;
        // cpu.v gates CPUWR_N with EN in plain carts.
        pin_ce = (gsu_mode && ~enable_q) ? 1'b0 : s_ce;
        pin_rd = ~enable_q ? 1'b1 : s_rd;   // CPURD_CYC_N is EN-gated (cpu.v)
        pin_we = ~enable_q ? 1'b1 : s_we;
    end
end

// ---- save-channel streamer (iosys discipline: one toggle at a time)
reg stream_on = 0, stream_write = 0;
reg [17:0] stream_base = 18'h08000;
integer stream_i = 0;
reg stream_busy = 0;
assign stream_busy_h = stream_busy;
reg [17:0] stream_pend_addr = 0;
reg [7:0] stream_pend_data = 0;
integer scen_kind = 0, scen_off = 0, scen_len = 0, scen_bank = 0;
reg scen_pause = 0;   // window kind for the next scenario: 1 = firmware pause
always @(negedge clk) begin
    if (stream_busy) begin
        if (stream_write && dut.sv_ack_r === sv_req_r) begin
            stream_busy <= 0;
            gmem[stream_pend_addr[16:0]] <= stream_pend_data;
        end else if (!stream_write && dut.sv_rack_r === sv_rreq_r) begin
            stream_busy <= 0;
            if (dut.sv_q_r !== gmem[stream_pend_addr[16:0]])
                $fatal(1, "save dump byte wrong: addr %h got %h want %h (kind %0d off %0d len %0d bank %0d)",
                       stream_pend_addr, dut.sv_q_r, gmem[stream_pend_addr[16:0]],
                       scen_kind, scen_off, scen_len, scen_bank);
        end
    end else if (stream_on) begin
        stream_pend_addr <= stream_base + (stream_i[9:0]);
        stream_busy <= 1;
        if (stream_write) begin
            sv_addr_r <= stream_base + (stream_i[9:0]);
            stream_pend_data <= stream_i[7:0] ^ 8'hA6;
            sv_din_r <= stream_i[7:0] ^ 8'hA6;
            sv_req_r <= ~sv_req_r;
        end else begin
            sv_addr_r <= stream_base + (stream_i[9:0]);
            sv_rreq_r <= ~sv_rreq_r;
        end
        stream_i <= stream_i + 1;
    end
end

// ---- helpers ------------------------------------------------------
task drain;                       // stream off, FIFO empty, not busy
    integer quiet, t;
    begin
        stream_on = 0;
        // A save toggle left pending can only ack in a pause window:
        // hold one open until the streamer and the bridge go idle.
        win_pause = 1; halt_wait_idle = 0;
        halt_at = cyc + 1; halt_len = 100000;
        quiet = 0; t = 0;
        while (quiet < 10 && t < 5000) begin
            @(negedge clk); t = t + 1;
            if (dut.bs_fifo_empty && !dut.bs_busy && !stream_busy && gst == ST_IDLE)
                quiet = quiet + 1;
            else quiet = 0;
        end
        halt_at = -1; win_pause = 0;
        quiet = 0; t = 0;
        while (quiet < 40 && t < 5000) begin
            @(negedge clk); t = t + 1;
            if (dut.bs_fifo_empty && !dut.bs_busy && !stream_busy && gst == ST_IDLE)
                quiet = quiet + 1;
            else quiet = 0;
        end
        if (quiet < 40)
            $fatal(1, "drain stuck (kind %0d off %0d len %0d)", scen_kind, scen_off, scen_len);
    end
endtask

task gsu_cmd(input [1:0] kind, input [16:0] a, input [15:0] d, input w);
    begin
        @(negedge clk);
        cmd_kind = kind; cmd_addr = a; cmd_data = d; cmd_word = w;
        cmd_pend = 1; done_flag = 0;
    end
endtask

task gsu_wait_done;
    integer t;
    begin
        t = 0;
        while (!done_flag && t < 20000) begin @(negedge clk); t = t + 1; end
        if (!done_flag)
            $fatal(1, "GSU access never completed (kind %0d off %0d len %0d bank %0d) gst=%0d cnt=%0d gen=%b en=%b pause=%b win=%b busy=%b fifoempty=%b bsbusy=%b wait=%b cyc=%0d halt_at=%0d",
                   scen_kind, scen_off, scen_len, scen_bank, gst, gcnt, gen, enable_q, pause_q, in_window, stream_busy, dut.bs_fifo_empty, dut.bs_busy, dut.gsu_ram_wait, cyc, halt_at);
        @(negedge clk); done_flag = 0;
    end
endtask

// One GSU scenario: issue the access, drop enable `off` cycles after
// the command cycle for `hln` cycles, streamer as configured.
task gsu_scen(input [1:0] kind, input [16:0] a, input [15:0] d, input w,
              input integer off, input integer hln);
    reg [7:0] want0, want1;
    begin
        scen_kind = kind; scen_off = off; scen_len = hln; scen_bank = a[16];
        want0 = gmem[a]; want1 = gmem[a ^ 17'd1];
        gsu_cmd(kind, a, d, w);
        win_pause = scen_pause; halt_wait_idle = scen_pause;
        halt_at = cyc + off; halt_len = hln;
        if (kind == ST_SAVE) begin
            gmem[a] = d[7:0];
            if (w) gmem[a ^ 17'd1] = d[15:8];
        end
        if (kind == ST_PCF) gmem[a] = want0 ^ 8'hFF;
        gsu_wait_done;
        halt_at = -1;
        if (kind == ST_LOAD) begin
            if (cap_data[7:0] !== want0)
                $fatal(1, "GSU LOAD byte0 wrong: addr %h got %h want %h (off %0d len %0d streamw %0d delay %0d)",
                       a, cap_data[7:0], want0, off, hln, stream_write, delaymax);
            if (w && cap_data[15:8] !== want1)
                $fatal(1, "GSU LOAD byte1 wrong: addr %h got %h want %h (off %0d len %0d streamw %0d delay %0d)",
                       a, cap_data[15:8], want1, off, hln, stream_write, delaymax);
        end
        if (kind == ST_PCF && cap_pcf !== want0)
            $fatal(1, "GSU PCF read wrong: addr %h got %h want %h (off %0d len %0d streamw %0d delay %0d)",
                   a, cap_pcf, want0, off, hln, stream_write, delaymax);
        drain;
        if (kind == ST_SAVE || kind == ST_PCF) begin
            if (mem[a] !== gmem[a])
                $fatal(1, "SDRAM byte wrong after write: addr %h got %h want %h (off %0d len %0d streamw %0d delay %0d)",
                       a, mem[a], gmem[a], off, hln, stream_write, delaymax);
            if (kind == ST_SAVE && w && mem[a ^ 17'd1] !== gmem[a ^ 17'd1])
                $fatal(1, "SDRAM byte1 wrong after write: addr %h got %h want %h (off %0d len %0d)",
                       a, mem[a ^ 17'd1], gmem[a ^ 17'd1], off, hln);
        end
    end
endtask

reg survey = 0;
integer scpu_errors = 0;
integer sample_at = 6;
// S-CPU read: present at negedge, sample after `sample_at` enabled
// posedges (default 6: the bsram_bridge #65 sample point for this
// controller model -- after an unqueued service, before a
// queued-behind-save service).
task scpu_read_check(input [19:0] a);
    integer n;
    begin
        @(negedge clk); s_addr = a; s_ce = 0; s_we = 1; s_rd = 0;
        n = 0;
        while (n < sample_at) begin
            @(posedge clk);
            if (enable_q) n = n + 1;
        end
        @(negedge clk);
        if (q !== gmem[a[16:0]]) begin
            if (survey) begin
                scpu_errors = scpu_errors + 1;
                $display("MISMATCH S-CPU read: addr %h got %h want %h (kind %0d off %0d len %0d streamw %0d delay %0d gsu %0d)",
                         a, q, gmem[a[16:0]], scen_kind, scen_off, scen_len, stream_write, delaymax, gsu_mode);
            end else
                $fatal(1, "S-CPU read wrong: addr %h got %h want %h (off %0d len %0d streamw %0d delay %0d gsu %0d)",
                       a, q, gmem[a[16:0]], scen_off, scen_len, stream_write, delaymax, gsu_mode);
        end
        s_ce = 1; s_rd = 1;
    end
endtask

// S-CPU read presented `pre` cycles before the halt falls; its
// sample (5 enabled cycles after presentation) lands after resume.
task scpu_pre_scen(input [19:0] a, input integer pre, input integer hln);
    begin
        scen_kind = 8; scen_off = pre; scen_len = hln; scen_bank = a[16];
        win_pause = scen_pause; halt_wait_idle = scen_pause;
        halt_at = cyc + pre + 1; halt_len = hln;
        scpu_read_check(a);
        halt_at = -1;
        drain;
    end
endtask

// S-CPU write whose WE window (4 enabled cycles) crosses the halt.
task scpu_write_scen(input [19:0] a, input [7:0] d, input integer pre, input integer hln);
    integer n;
    begin
        scen_kind = 7; scen_off = pre; scen_len = hln; scen_bank = a[16];
        win_pause = scen_pause; halt_wait_idle = scen_pause;
        halt_at = cyc + pre + 1; halt_len = hln;
        @(negedge clk); s_addr = a; s_din = d; s_ce = 0; s_we = 0; s_rd = 1;
        gmem[a[16:0]] = d;
        n = 0;
        while (n < 4) begin
            @(posedge clk);
            if (enable_q) n = n + 1;
        end
        @(negedge clk); s_ce = 1; s_we = 1;
        halt_at = -1;
        drain;
        if (mem[a[16:0]] !== d)
            $fatal(1, "S-CPU write lost across halt: addr %h got %h want %h (pre %0d len %0d)",
                   a, mem[a[16:0]], d, pre, hln);
    end
endtask

task scpu_write(input [19:0] a, input [7:0] d);
    begin
        @(negedge clk); s_addr = a; s_din = d; s_ce = 0; s_we = 0; s_rd = 1;
        gmem[a[16:0]] = d;
        repeat (4) @(negedge clk);
        s_ce = 1; s_we = 1;
    end
endtask

// S-CPU scenario: halt of `hln` starts now; the read is presented
// `off` cycles after enable rises again (the resume window).
task scpu_resume_scen(input [19:0] a, input integer off, input integer hln);
    integer t;
    begin
        scen_kind = 9; scen_off = off; scen_len = hln; scen_bank = a[16];
        win_pause = scen_pause; halt_wait_idle = scen_pause;
        halt_at = cyc + 1; halt_len = hln;
        // wait until enable has fallen and risen again
        while (enable_q) @(negedge clk);
        if (scen_pause) begin
            // The firmware sender toggles no new byte once the dump is
            // done; it unpauses only after the last ack. Stop the
            // streamer near the window end so the pending byte is the
            // last one.
            while (cyc < halt_at + hln - 100) @(negedge clk);
            stream_on = 0;
        end
        while (!enable_q) @(negedge clk);
        halt_at = -1;
        for (t = 0; t < off; t = t + 1) @(negedge clk);
        scpu_read_check(a);
        drain;
    end
endtask

integer i, off, hln, bank, section = 0, pre;
reg [16:0] ta;
initial begin
    if (!$value$plusargs("DELAY=%d", delaymax)) delaymax = 3;
    if (!$value$plusargs("SECTION=%d", section)) section = 0; // 0 all, 1 GSU, 2 S-CPU
    if (!$value$plusargs("SAMPLE=%d", sample_at)) sample_at = 6;
    survey = $test$plusargs("SURVEY");
    for (i = 0; i < 131072; i = i + 1) begin
        mem[i] = (i ^ (i >> 8) ^ 8'h5A);
        gmem[i] = mem[i];
        if (i < 65536) dut.bs_mirror[i] = mem[i];
    end
    repeat (8) @(negedge clk);

  if (section != 2) begin
    // ---- GSU accesses crossing enable-low windows ------------------
    // streamer on (dump reads), then restore writes; two halt lengths
    // (short per-frame halt and a long pause), phase swept.
    for (bank = 0; bank < 2; bank = bank + 1) begin
        stream_base = bank ? 18'h08000 : 18'h18000;
        for (hln = 24; hln <= 240; hln = hln * 10) begin
            stream_write = 0; stream_on = 1;
            for (off = 0; off < 22; off = off + 1) begin
                ta = {bank[0], 16'h0100} + off * 17'd2;
                gsu_scen(ST_LOAD, ta, 16'h0, 0, off, hln); stream_on = 1;
                gsu_scen(ST_LOAD, ta, 16'h0, 1, off, hln); stream_on = 1;
                gsu_scen(ST_SAVE, ta, {off[7:0] ^ 8'hC3, off[7:0] ^ 8'h3C}, 1, off, hln); stream_on = 1;
                gsu_scen(ST_SAVE, ta, 16'h00E7, 0, off, hln); stream_on = 1;
                gsu_scen(ST_PCF, ta, 16'h0, 0, off, hln); stream_on = 1;
            end
            stream_write = 1; stream_on = 1;
            for (off = 0; off < 22; off = off + 1) begin
                ta = {bank[0], 16'h0200} + off * 17'd2;
                gsu_scen(ST_LOAD, ta, 16'h0, 1, off, hln); stream_on = 1;
                gsu_scen(ST_SAVE, ta, {off[7:0] ^ 8'h96, off[7:0] ^ 8'h69}, 1, off, hln); stream_on = 1;
                gsu_scen(ST_PCF, ta, 16'h0, 0, off, hln); stream_on = 1;
            end
            stream_on = 0;
        end
    end
    // Long pause (menu) with a dump streaming: the transcript shape.
    scen_pause = 1; stream_write = 0; stream_on = 1;
    for (off = 0; off < 22; off = off + 1) begin
        ta = {1'b1, 16'h0300} + off * 17'd2;
        gsu_scen(ST_LOAD, ta, 16'h0, 1, off, 4000); stream_on = 1;
        ta = {1'b0, 16'h0300} + off * 17'd2;
        gsu_scen(ST_SAVE, ta, 16'hB6A5, 1, off, 4000); stream_on = 1;
    end
    stream_on = 0; scen_pause = 0;
    // CLS=0 (RAM_CYCLES 1, GSU1 clocking) spot sweep.
    speed = 0; stream_write = 0; stream_on = 1;
    for (off = 0; off < 16; off = off + 1) begin
        ta = {1'b1, 16'h0400} + off * 17'd2;
        gsu_scen(ST_LOAD, ta, 16'h0, 1, off, 60); stream_on = 1;
        ta = {1'b0, 16'h0400} + off * 17'd2;
        gsu_scen(ST_SAVE, ta, 16'h5AA5, 1, off, 60); stream_on = 1;
    end
    stream_on = 0; speed = 1;
  end

  if (section != 1) begin
    // ---- S-CPU reads around the resume edge -------------------------
    // Plain cartridge (gsu_mode=0) and GSU cartridge with the GSU idle.
    gsu_active = 0;
    for (bank = 0; bank < 2; bank = bank + 1) begin
        gsu_mode = bank; rom_type = bank ? 8'h70 : 8'h00;
        stream_base = bank ? 18'h08000 : 18'h18000;
        // Control: same shapes with no save traffic must all pass
        // (validates the sample point against this controller delay).
        stream_write = 0; stream_on = 0;
        for (off = 0; off < 14; off = off + 1) begin
            scpu_resume_scen(20'h10700 + off, off, 240);
            scpu_pre_scen(20'h10740 + off, off % 8, 240);
        end
        stream_write = 0; stream_on = 1;
        for (off = 0; off < 14; off = off + 1) begin
            scpu_write(20'h00500 + off, off[7:0] ^ 8'hA5);
            drain; stream_on = 1;
            scpu_resume_scen(20'h00500 + off, off, 240); stream_on = 1;
        end
        stream_write = 1; stream_on = 1;
        for (off = 0; off < 14; off = off + 1) begin
            scpu_resume_scen(20'h10500 + off, off, 240); stream_on = 1;
        end
        stream_on = 0;
        // Same resume sweep through firmware-pause windows (the pause
        // lasts until the pending save byte has acked).
        scen_pause = 1; stream_write = 0; stream_on = 1;
        for (off = 0; off < 14; off = off + 1) begin
            scpu_resume_scen(20'h00580 + off, off, 240); stream_on = 1;
        end
        scen_pause = 0; stream_on = 0;
        // Presented before the halt, sampled after resume; and writes
        // whose WE window crosses the halt. Short halt and long pause.
        stream_write = 0; stream_on = 1;
        for (pre = 0; pre < 8; pre = pre + 1) begin
            scen_pause = 0;
            scpu_pre_scen(20'h00600 + pre, pre, 240); stream_on = 1;
            scpu_write_scen(20'h00640 + pre, pre[7:0] ^ 8'h6B, pre, 240); stream_on = 1;
            scen_pause = 1;
            scpu_pre_scen(20'h10600 + pre, pre, 4000); stream_on = 1;
            scpu_write_scen(20'h10640 + pre, pre[7:0] ^ 8'hB6, pre, 4000); stream_on = 1;
        end
        scen_pause = 0;
        stream_on = 0;
    end
  end

    if (scpu_errors)
        $fatal(1, "gsu_save_halt: %0d S-CPU read mismatches (survey)", scpu_errors);
    $display("PASS: gsu_save_halt delay=%0d section=%0d requests=%0d cycles=%0d", delaymax, section, requests, cyc);
    $finish;
end
initial begin #30000000; $fatal(1, "timeout"); end
endmodule
